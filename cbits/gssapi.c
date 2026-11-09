/* A small ownership boundary around the platform GSSAPI ABI. All calls for one
 * context run on its Haskell worker. Output remains owned by that context until
 * the next step or close; Haskell copies it before making another request. */
#ifdef _WIN32
unsigned int mariadb_gss_live_contexts(void) { return 0; }
#else
#ifdef __APPLE__
#include <GSS/GSS.h>
#else
#include <gssapi/gssapi.h>
#endif
#include <stdlib.h>
#include <stdatomic.h>

/* A credential-free diagnostic also used by cancellation/leak regressions. */
static _Atomic unsigned int live_contexts = 0;
unsigned int mariadb_gss_live_contexts(void) { return atomic_load(&live_contexts); }

struct mariadb_gss_context {
    gss_name_t service;
    gss_ctx_id_t context;
    gss_cred_id_t credentials;
    gss_buffer_desc output;
    gss_OID_desc mechanism;
    int counted;
};

void mariadb_gss_close(struct mariadb_gss_context *state)
{
    OM_uint32 minor;
    if (!state) return;
    if (state->output.value) gss_release_buffer(&minor, &state->output);
    if (state->context != GSS_C_NO_CONTEXT)
        gss_delete_sec_context(&minor, &state->context, GSS_C_NO_BUFFER);
    if (state->credentials != GSS_C_NO_CREDENTIAL)
        gss_release_cred(&minor, &state->credentials);
    if (state->service != GSS_C_NO_NAME)
        gss_release_name(&minor, &state->service);
    if (state->counted) atomic_fetch_sub(&live_contexts, 1);
    free(state);
}

int mariadb_gss_open(const char *principal, size_t length, int negotiate,
                     struct mariadb_gss_context **result,
                     OM_uint32 *major, OM_uint32 *minor)
{
    static unsigned char kerberos[] = {0x2a,0x86,0x48,0x86,0xf7,0x12,0x01,0x02,0x02};
    static unsigned char spnego[] = {0x2b,0x06,0x01,0x05,0x05,0x02};
    struct mariadb_gss_context *state = calloc(1, sizeof(*state));
    gss_buffer_desc name = {length, (void *)principal};
    gss_OID_desc kerberos_mechanism = {sizeof(kerberos), kerberos};
    gss_OID_set_desc desired_mechanisms = {1, &kerberos_mechanism};
    *result = NULL;
    *major = *minor = 0;
    if (!state) return 1;
    state->service = GSS_C_NO_NAME;
    state->context = GSS_C_NO_CONTEXT;
    state->credentials = GSS_C_NO_CREDENTIAL;
    state->mechanism.length = negotiate ? sizeof(spnego) : sizeof(kerberos);
    state->mechanism.elements = negotiate ? spnego : kerberos;
    *major = gss_import_name(minor, &name, GSS_C_NT_USER_NAME, &state->service);
    if (GSS_ERROR(*major)) {
        mariadb_gss_close(state);
        return 2;
    }
    /* Acquire only Kerberos credentials. In particular, a server selecting
     * SPNEGO must not cause the OS to try cached NTLM/other credentials. The
     * explicit credential lease is owned and released with this context. */
    *major = gss_acquire_cred(minor, GSS_C_NO_NAME, 0, &desired_mechanisms,
        GSS_C_INITIATE, &state->credentials, NULL, NULL);
    if (GSS_ERROR(*major)) {
        mariadb_gss_close(state);
        return 2;
    }
    state->counted = 1;
    atomic_fetch_add(&live_contexts, 1);
    *result = state;
    return 0;
}

int mariadb_gss_step(struct mariadb_gss_context *state,
                     const char *input, size_t length,
                     const char **output, size_t *output_length, int *complete,
                     OM_uint32 *major, OM_uint32 *minor)
{
    OM_uint32 flags = 0, ignored;
    gss_buffer_desc token = {length, (void *)input};
    if (state->output.value) gss_release_buffer(&ignored, &state->output);
    state->output.value = NULL;
    state->output.length = 0;
    *output = NULL;
    *output_length = 0;
    *complete = 0;
    /* No delegation: the server receives a service ticket, never a TGT. Mutual
     * authentication binds its reply to the explicitly pinned principal. */
    *major = gss_init_sec_context(minor, state->credentials, &state->context,
        state->service, &state->mechanism, GSS_C_MUTUAL_FLAG, 0,
        GSS_C_NO_CHANNEL_BINDINGS, length ? &token : GSS_C_NO_BUFFER,
        NULL, &state->output, &flags, NULL);
    if (GSS_ERROR(*major)) return 2;
    if (state->output.length > 1048576) return 3;
    *complete = (*major & GSS_S_CONTINUE_NEEDED) == 0;
    if (*complete && !(flags & GSS_C_MUTUAL_FLAG)) return 4;
    *output = state->output.value;
    *output_length = state->output.length;
    return 0;
}

#endif /* !_WIN32 */
