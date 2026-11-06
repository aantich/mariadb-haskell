/* Matching text-protocol control using the installed MariaDB Connector/C.
 * Same SQL, ASCII payload, numeric parsing, checksums, warmups and transactions
 * as Validation.Benchmark. Haskell-only binary/TLS/micro workloads are separate.
 */
#include <mysql.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <time.h>
#include <sys/resource.h>

static MYSQL *db;
static const char *name;
static int count;
static uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ULL + t.tv_nsec;
}
static uint64_t cpu_ns(void) {
    struct rusage r;
    getrusage(RUSAGE_SELF, &r);
    return ((uint64_t)r.ru_utime.tv_sec+r.ru_stime.tv_sec)*1000000000ULL
         + ((uint64_t)r.ru_utime.tv_usec+r.ru_stime.tv_usec)*1000ULL;
}
static void die(void) { fprintf(stderr,"Connector/C: %s\n",mysql_error(db)); exit(1); }
static void execute(const char *q) {
    if (mysql_real_query(db,q,strlen(q))) die();
    int next;
    do {
        MYSQL_RES *result=mysql_store_result(db);
        if (result) mysql_free_result(result);
        else if (mysql_field_count(db)) die();
        next=mysql_next_result(db);
        if (next>0) die();
    } while (next==0);
}
static uint64_t fetch(const char *q) {
    if (mysql_real_query(db,q,strlen(q))) die();
    MYSQL_RES *result=mysql_use_result(db);
    if (!result) die();
    MYSQL_FIELD *fields=mysql_fetch_fields(result);
    unsigned n=mysql_num_fields(result);
    MYSQL_ROW row;
    uint64_t checksum=0;
    while ((row=mysql_fetch_row(result))) {
        unsigned long *lengths=mysql_fetch_lengths(result);
        for (unsigned i=0;i<n;i++) if (row[i]) {
            switch (fields[i].type) {
                case MYSQL_TYPE_TINY: case MYSQL_TYPE_SHORT:
                case MYSQL_TYPE_LONG: case MYSQL_TYPE_LONGLONG:
                case MYSQL_TYPE_INT24: case MYSQL_TYPE_DECIMAL:
                case MYSQL_TYPE_NEWDECIMAL:
                    checksum+=(uint64_t)strtoll(row[i],NULL,10); break;
                default: checksum+=lengths[i]; break;
            }
        }
    }
    if (mysql_errno(db)) die();
    mysql_free_result(result);
    return checksum;
}
static uint64_t action(void) {
    if (!strcmp(name,"latency.text")) return fetch("SELECT 1");
    if (!strcmp(name,"read.text.narrow")) return fetch("SELECT id,n,payload FROM mb_bench_data ORDER BY id");
    if (!strcmp(name,"read.text.wide")) {
        char q[2048]="SELECT id,n";
        for (int i=0;i<30;i++) strcat(q,",payload");
        strcat(q," FROM mb_bench_data ORDER BY id");
        return fetch(q);
    }
    if (!strcmp(name,"blob.text")) return fetch("SELECT CAST(REPEAT('x',1048576) AS BINARY)");
    execute("TRUNCATE TABLE mb_bench_write");
    execute("BEGIN");
    if (!strcmp(name,"write.execute-many")) {
        size_t capacity=(size_t)count*80+1;
        char *q=calloc(capacity,1);
        if (!q) exit(2);
        size_t offset=0;
        for (int i=1;i<=count;i++) offset+=(size_t)snprintf(q+offset,capacity-offset,
            "%sINSERT INTO mb_bench_write(n) VALUES(%d)",i==1?"":";",i);
        execute(q); free(q);
    } else {
        char q[128];
        for (int i=1;i<=count;i++) {
            snprintf(q,sizeof(q),"INSERT INTO mb_bench_write(n) VALUES(%d)",i);
            execute(q);
        }
    }
    execute("COMMIT");
    if (fetch("SELECT COUNT(*) FROM mb_bench_write")!=(uint64_t)count) {
        fprintf(stderr,"inserted row count mismatch\n"); exit(1);
    }
    return fetch("SELECT COALESCE(SUM(n),0) FROM mb_bench_write");
}
int main(int argc,char **argv) {
    if (argc==2 && !strcmp(argv[1],"--version")) { puts(mysql_get_client_info()); return 0; }
    if (argc!=3) { fprintf(stderr,"usage: connector-c BENCH ITERATIONS\n"); return 2; }
    name=argv[1]; count=atoi(argv[2]);
    if (count<=0) return 2;
    const char *host=getenv("MB_HOST"),*user=getenv("MB_USER"),*pass=getenv("MB_PASSWORD"),*database=getenv("MB_DATABASE");
    db=mysql_init(NULL);
    unsigned timeout=5;
    mysql_options(db,MYSQL_OPT_CONNECT_TIMEOUT,&timeout);
    mysql_options(db,MYSQL_SET_CHARSET_NAME,"utf8mb4");
    if (!mysql_real_connect(db,host?host:"127.0.0.1",user,pass,database,
        getenv("MB_PORT")?(unsigned)atoi(getenv("MB_PORT")):3306,NULL,CLIENT_MULTI_STATEMENTS)) die();
    if (mysql_get_ssl_cipher(db)) { fprintf(stderr,"unexpected TLS in plaintext control\n"); return 1; }
    int iterations=count,units=1;
    uint64_t expected=1;
    if (!strcmp(name,"read.text.narrow")) { units=10000; expected=201300000; }
    else if (!strcmp(name,"read.text.wide")) { units=10000; expected=238420000; }
    else if (!strcmp(name,"blob.text")) { units=1048576; expected=1048576; }
    else if (!strcmp(name,"write.text") || !strcmp(name,"write.execute-many")) {
        units=count; iterations=1; expected=(uint64_t)count*(count+1)/2;
        execute("CREATE TEMPORARY TABLE mb_bench_write(n BIGINT) ENGINE=InnoDB");
    } else if (strcmp(name,"latency.text")) { fprintf(stderr,"unsupported control workload\n"); return 3; }
    for (int i=0;i<2;i++) if (action()!=expected) { fprintf(stderr,"warm-up checksum mismatch\n"); return 1; }
    uint64_t *samples=calloc((size_t)iterations,sizeof(uint64_t));
    if (!samples) return 2;
    uint64_t checksum=0,cpu0=cpu_ns(),start=now_ns();
    for (int i=0;i<iterations;i++) {
        uint64_t t=now_ns(),v=action();
        samples[i]=now_ns()-t;
        if (v!=expected) { fprintf(stderr,"benchmark checksum mismatch\n"); return 1; }
        checksum+=v;
    }
    uint64_t elapsed=now_ns()-start,cpu=cpu_ns()-cpu0;
    printf("BENCH\t%s\t%d\t%" PRIu64 "\t-1\t-1\t-1\t%" PRIu64 "\t%" PRIu64 "\t",name,iterations*units,elapsed,cpu,checksum);
    for (int i=0;i<iterations;i++) printf("%s%" PRIu64,i?",":"",samples[i]);
    putchar('\n'); free(samples);
    mysql_close(db);
    return 0;
}
