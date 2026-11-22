/* Synthetic test helper: make a required sandbox syscall unavailable. */
#define _GNU_SOURCE
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <unistd.h>
int main(int argc,char **argv) {
    if (argc<5) return 125;
    unsigned nr=strtoul(argv[1],NULL,10),arg0=strtoul(argv[2],NULL,10);
    struct sock_filter code[]={
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,nr)),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,nr,0,4),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,arg0==~0U ? nr : ~0U,2,0),
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,args[0])),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,arg0,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|38),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW)
    };
    struct sock_fprog filter={.len=sizeof(code)/sizeof(code[0]),.filter=code};
    if (prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0) || prctl(PR_SET_SECCOMP,SECCOMP_MODE_FILTER,&filter)) return 125;
    execv(argv[3],&argv[3]);return 125;
}
