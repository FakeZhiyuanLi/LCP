/* Linux x86_64 launcher: establish the boundary before executing Python.
 * Build: cc -O2 -Wall -Wextra -Werror -D_FORTIFY_SOURCE=3 -fstack-protector-strong
 *        -Wl,-z,relro,-z,now -o lcp-export-sandbox sandbox.c
 * No privilege, namespaces, environment overrides, or unsandboxed fallback.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/landlock.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>

#if !defined(__x86_64__) || defined(__ILP32__)
#error Reviewed sandbox supports Linux x86_64 only; fail closed elsewhere.
#endif

static void fail(const char *message) {
    fprintf(stderr, "desktop_sandbox_rejected:%s (errno=%d)\n", message, errno);
    exit(126);
}
static int safe_dir(const char *path) {
    if (path[0] != '/' || strlen(path) >= PATH_MAX) fail("absolute_directory_required");
    int fd = open("/", O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) fail("root_open");
    char copy[PATH_MAX];
    strcpy(copy, path);
    char *save, *part = strtok_r(copy, "/", &save);
    while (part) {
        if (!strcmp(part, ".") || !strcmp(part, "..")) fail("unsafe_directory");
        int next = openat(fd, part, O_PATH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) fail("directory_symlink_or_unavailable");
        close(fd); fd=next;
        part = strtok_r(NULL, "/", &save);
    }
    return fd;
}
static int beneath(const char *parent, const char *child) {
    size_t n=strlen(parent);
    return !strncmp(parent,child,n) && (child[n]=='/' || child[n]=='\0');
}
static unsigned entries;
static void audit_output(int anchor, unsigned depth) {
    if (depth > 8) fail("output_depth");
    int fd=openat(anchor,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if (fd < 0) fail("output_open");
    struct stat st;
    if (fstat(fd,&st) || st.st_uid!=getuid() || (st.st_mode & 077)) fail("output_not_private");
    DIR *dir=fdopendir(fd);
    if (!dir) fail("output_directory");
    struct dirent *entry;
    errno=0;
    while ((entry=readdir(dir))) {
        if (!strcmp(entry->d_name,".") || !strcmp(entry->d_name,"..")) continue;
        if (++entries > 12000) fail("output_entries");
        if (fstatat(fd,entry->d_name,&st,AT_SYMLINK_NOFOLLOW)) fail("output_stat");
        if (st.st_uid!=getuid() || (st.st_mode & 077)) fail("output_entry_not_private");
        if (S_ISDIR(st.st_mode)) {
            int child=openat(fd,entry->d_name,O_PATH|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
            if (child<0) fail("output_directory_changed");
            audit_output(child,depth+1); close(child);
        } else if (!S_ISREG(st.st_mode) || st.st_nlink!=1) {
            fail("output_alias_or_nonregular");
        }
        errno=0;
    }
    if (errno) fail("output_enumeration");
    closedir(dir);
}
static void sanitize_fds(void) {
    /* Landlock does not revoke access already granted to open descriptors. */
    int null=open("/dev/null",O_RDONLY|O_CLOEXEC);
    if (null<0 || dup2(null,0)<0) _exit(126);
    if (null!=0) close(null);
    int unsafe=0;
    for (int fd=1;fd<=2;fd++) {
        struct stat st;
        if (fstat(fd,&st)) _exit(126);
        if (S_ISFIFO(st.st_mode)) continue;
        if (S_ISSOCK(st.st_mode)) {
            struct sockaddr_un peer={0}; socklen_t length=sizeof(peer);
            if (!getpeername(fd,(struct sockaddr *)&peer,&length) && peer.sun_family==AF_UNIX &&
                !strcmp(peer.sun_path,"/run/systemd/journal/stdout")) continue;
        }
        /* Never inherit writable files, terminals, or arbitrary control sockets. */
        /* Do not print even a rejection into an inherited source-file stderr. */
        int sink=open("/dev/null",O_WRONLY|O_CLOEXEC);
        if (sink<0 || dup2(sink,fd)<0) _exit(126);
        if (sink!=fd) close(sink);
        unsafe=1;
    }
    if (unsafe) fail("unsafe_stdout_or_stderr");
    if (syscall(SYS_close_range,3U,~0U,0)) fail("close_range_unavailable");
}
static void rule(int ruleset, int fd, uint64_t access) {
    struct landlock_path_beneath_attr attr={.allowed_access=access,.parent_fd=fd};
    if (syscall(SYS_landlock_add_rule,ruleset,LANDLOCK_RULE_PATH_BENEATH,&attr,0)) fail("landlock_rule");
}
static void read_path(int ruleset,const char *path,uint64_t access) {
    int fd=open(path,O_PATH|O_CLOEXEC);
    if (fd<0) fail("runtime_path_unavailable");
    rule(ruleset,fd,access);close(fd);
}
static void source_file(int ruleset,int parent,const char *name) {
    int fd=openat(parent,name,O_PATH|O_NOFOLLOW|O_CLOEXEC);
    struct stat st;
    if (fd<0 || fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_nlink!=1) fail("unsafe_source_metadata");
    rule(ruleset,fd,LANDLOCK_ACCESS_FS_READ_FILE);close(fd);
}

#define ALLOW(name) BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,SYS_##name,0,1), BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW)
static void syscall_filter(void) {
    /* Default deny: includes metadata mutation, networking/IPC, process control,
     * fd acquisition, io_uring, mounting, privilege changes, and unknown calls.
     * Python is single process; no fork/clone. Landlock further limits every
     * allowed filesystem open/create/remove/link/rename/truncate operation.
     */
    struct sock_filter code[]={
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,arch)),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,AUDIT_ARCH_X86_64,1,0),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_KILL_PROCESS),
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,nr)),
        /* CPython's script fopen uses FIOCLEX. No device ioctls are admitted. */
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,SYS_ioctl,0,4),
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,args[1])),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,FIOCLEX,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM),
        /* Limit descriptor configuration; no leases, owners, or notifications. */
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,SYS_fcntl,0,14),
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,args[1])),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,F_GETFD,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,F_SETFD,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,F_GETFL,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,F_SETFL,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,F_DUPFD,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,F_DUPFD_CLOEXEC,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,SYS_prlimit64,0,4),
        BPF_STMT(BPF_LD|BPF_W|BPF_ABS,offsetof(struct seccomp_data,args[0])),
        BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,0,0,1),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM),
        ALLOW(read), ALLOW(write), ALLOW(close), ALLOW(close_range),
        ALLOW(fstat), ALLOW(newfstatat), ALLOW(stat), ALLOW(lstat), ALLOW(statx),
        ALLOW(lseek), ALLOW(pread64), ALLOW(pwrite64), ALLOW(readv), ALLOW(writev),
        ALLOW(open), ALLOW(openat), ALLOW(openat2), ALLOW(getdents64),
        ALLOW(readlink), ALLOW(readlinkat), ALLOW(access), ALLOW(faccessat), ALLOW(faccessat2),
        ALLOW(mmap), ALLOW(mprotect), ALLOW(munmap), ALLOW(mremap), ALLOW(brk), ALLOW(madvise),
        ALLOW(rt_sigaction), ALLOW(rt_sigprocmask), ALLOW(rt_sigreturn), ALLOW(sigaltstack),
        ALLOW(flock), ALLOW(dup), ALLOW(dup2), ALLOW(dup3),
        ALLOW(mkdir), ALLOW(mkdirat), ALLOW(unlink), ALLOW(unlinkat), ALLOW(rmdir),
        ALLOW(link), ALLOW(linkat), ALLOW(symlink), ALLOW(symlinkat),
        ALLOW(rename), ALLOW(renameat), ALLOW(renameat2),
        ALLOW(truncate), ALLOW(ftruncate), ALLOW(fsync), ALLOW(fdatasync),
        ALLOW(getcwd), ALLOW(chdir), ALLOW(fchdir), ALLOW(umask),
        ALLOW(getpid), ALLOW(getppid), ALLOW(gettid), ALLOW(getuid), ALLOW(geteuid),
        ALLOW(getgid), ALLOW(getegid), ALLOW(getgroups),
        ALLOW(futex), ALLOW(set_tid_address), ALLOW(set_robust_list), ALLOW(rseq),
        ALLOW(clock_gettime), ALLOW(gettimeofday), ALLOW(time), ALLOW(getrandom),
        ALLOW(uname), ALLOW(sysinfo), ALLOW(getrlimit), ALLOW(getrusage),
        ALLOW(arch_prctl), ALLOW(sched_getaffinity), ALLOW(sched_yield),
        ALLOW(poll), ALLOW(ppoll), ALLOW(select), ALLOW(pselect6),
        ALLOW(nanosleep), ALLOW(clock_nanosleep), ALLOW(restart_syscall),
        ALLOW(execve), ALLOW(exit), ALLOW(exit_group),
        BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM)
    };
    struct sock_fprog program={.len=sizeof(code)/sizeof(code[0]),.filter=code};
    if (prctl(PR_SET_SECCOMP,SECCOMP_MODE_FILTER,&program)) fail("seccomp_unavailable");
}
int main(int argc,char **argv) {
    sanitize_fds();umask(0077);
    if (argc<6 || strcmp(argv[4],"--")) fail("usage_package_source_output_separator_command");
    char package_resolved[PATH_MAX];
    if (!realpath(argv[1],package_resolved)) fail("package_unavailable");
    const char *package=package_resolved,*source=argv[2],*output=argv[3];
    char canonical[PATH_MAX];
    for (int i=2;i<=3;i++) {
        if (!realpath(argv[i],canonical) || strcmp(argv[i],canonical)) fail("noncanonical_root");
    }
    if (beneath(source,output)||beneath(output,source)||beneath(package,output)||beneath(output,package)||
        beneath(source,package)||beneath(package,source)||
        beneath("/usr",output)||beneath("/etc",output)||beneath("/proc",output)||beneath("/dev",output)) fail("roots_overlap_or_unsafe");
    int pkg=safe_dir(package),src=safe_dir(source),out=safe_dir(output);
    audit_output(out,0);
    if (prctl(PR_SET_NO_NEW_PRIVS,1,0,0,0)) fail("no_new_privs");
    int abi=syscall(SYS_landlock_create_ruleset,NULL,0,LANDLOCK_CREATE_RULESET_VERSION);
    if (abi<6 || abi>8) fail("reviewed_landlock_abi6_through8_required");
    struct landlock_ruleset_attr attr={
        .handled_access_fs=(1ULL<<16)-1,
        .handled_access_net=LANDLOCK_ACCESS_NET_BIND_TCP|LANDLOCK_ACCESS_NET_CONNECT_TCP,
        .scoped=LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET|LANDLOCK_SCOPE_SIGNAL
    };
    int rs=syscall(SYS_landlock_create_ruleset,&attr,sizeof(attr),0);
    if (rs<0) fail("landlock_ruleset_unavailable");
    uint64_t read=LANDLOCK_ACCESS_FS_READ_FILE|LANDLOCK_ACCESS_FS_READ_DIR;
    read_path(rs,"/usr",read);
    read_path(rs,"/etc/ld.so.cache",LANDLOCK_ACCESS_FS_READ_FILE);
    read_path(rs,"/etc/localtime",LANDLOCK_ACCESS_FS_READ_FILE);
    char python[PATH_MAX];
    if (!realpath("/usr/bin/python3",python) || strcmp(argv[5],"/usr/bin/python3")) fail("python_command_required");
    read_path(rs,python,LANDLOCK_ACCESS_FS_EXECUTE);
    read_path(rs,"/lib64/ld-linux-x86-64.so.2",LANDLOCK_ACCESS_FS_EXECUTE);
    rule(rs,pkg,read);
    int state=openat(src,"state",O_PATH|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (state<0) fail("source_state");
    source_file(rs,state,"heads.json");
    int jobs=openat(state,"jobs",O_PATH|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (jobs<0) fail("source_jobs");
    rule(rs,jobs,LANDLOCK_ACCESS_FS_READ_FILE);
    int inbox=openat(src,"inbox",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if (inbox<0) fail("source_inbox");
    rule(rs,inbox,LANDLOCK_ACCESS_FS_READ_DIR);
    DIR *dir=fdopendir(inbox); if (!dir) fail("source_inbox_directory");
    struct dirent *entry;unsigned count=0;errno=0;
    while ((entry=readdir(dir))) {
        if (++count>10002) fail("inbox_entries");
        size_t len=strlen(entry->d_name);
        const char *suffix=".m4a.ready.json";size_t n=strlen(suffix);
        if (len>n && !strcmp(entry->d_name+len-n,suffix)) source_file(rs,inbox,entry->d_name);
        errno=0;
    }
    if (errno) fail("inbox_enumeration");
    closedir(dir);close(state);close(jobs);close(src);close(pkg);
    rule(rs,out,read|LANDLOCK_ACCESS_FS_WRITE_FILE|LANDLOCK_ACCESS_FS_TRUNCATE|
        LANDLOCK_ACCESS_FS_MAKE_REG|LANDLOCK_ACCESS_FS_MAKE_DIR|
        LANDLOCK_ACCESS_FS_REMOVE_FILE|LANDLOCK_ACCESS_FS_REMOVE_DIR|LANDLOCK_ACCESS_FS_REFER);
    close(out);
    if (syscall(SYS_landlock_restrict_self,rs,0)) fail("landlock_enforcement_unavailable");
    close(rs);
    syscall_filter();
    /* Explicit environment: no Python hooks, library injection, credentials,
     * service control sockets, or user configuration enters the interpreter. */
    char *env[]={"LANG=C.UTF-8","LC_ALL=C.UTF-8","TZ=UTC","PYTHONDONTWRITEBYTECODE=1",NULL};
    execve(argv[5],&argv[5],env);
    fail("python_exec");
}
