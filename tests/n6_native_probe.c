/* Deliberately native worker used only in a disposable qualification image. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/capability.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/ptrace.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>
#define CHECK(x) do { if(!(x)){fprintf(stderr,"probe failed line %d: %s\n",__LINE__,#x);return 2;} }while(0)
int main(int argc,char **argv) {
  CHECK(argc>=3);
  if(strstr(argv[1],"true")) {puts("{\"type\":\"success\",\"answers\":[\"ok\"],\"more\":false}");return 0;}
  CHECK(getuid()>=20000 && getuid()<=60000 && geteuid()==getuid() && getgid()==getuid());
  struct __user_cap_header_struct header={_LINUX_CAPABILITY_VERSION_3,0};
  struct __user_cap_data_struct caps[2]={{0},{0}};
  CHECK(syscall(SYS_capget,&header,caps)==0);
  CHECK(!(caps[0].effective|caps[1].effective|caps[0].permitted|caps[1].permitted));
  struct rlimit limit;
  CHECK(!getrlimit(RLIMIT_NPROC,&limit)&&limit.rlim_max==32);
  CHECK(!getrlimit(RLIMIT_NOFILE,&limit)&&limit.rlim_max==64);
  CHECK(!getrlimit(RLIMIT_FSIZE,&limit)&&limit.rlim_max==0);
  CHECK(!getrlimit(RLIMIT_CORE,&limit)&&limit.rlim_max==0);
  CHECK(mmap(NULL,(size_t)3*1024*1024*1024,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0)==MAP_FAILED);
  CHECK(open("/proc/self/environ",O_RDONLY)==-1);
  CHECK(open("/tmp/n6/controller.token",O_RDONLY)==-1);
  CHECK(open("/etc/passwd",O_RDONLY)==-1);
  CHECK(open("/escape",O_CREAT|O_WRONLY,0600)==-1);
  CHECK(mkdir("/escape",0700)==-1);
  CHECK(chroot(".")==-1 && errno==EPERM);
  CHECK(setuid(0)==-1 && errno==EPERM);
  CHECK(setsid()==-1 && errno==EPERM);
  CHECK(setpgid(0,0)==-1 && errno==EPERM);
  CHECK(kill(1,0)==-1 && errno==EPERM);
  CHECK(ptrace(PTRACE_ATTACH,1,0,0)==-1 && errno==EPERM);
  CHECK(prctl(PR_SET_DUMPABLE,1)==-1 && errno==EPERM);
  CHECK(unshare(CLONE_NEWUSER)==-1 && errno==EPERM);
  CHECK(socket(AF_INET,SOCK_STREAM,0)==-1 && errno==EPERM);
  CHECK(socket(AF_INET6,SOCK_DGRAM,0)==-1 && errno==EPERM);
  CHECK(socket(AF_PACKET,SOCK_RAW,0)==-1 && errno==EPERM);
  CHECK(socket(AF_NETLINK,SOCK_RAW,0)==-1 && errno==EPERM);
#ifdef SYS_io_uring_setup
  CHECK(syscall(SYS_io_uring_setup,1,NULL)==-1 && errno==EPERM);
#endif
  int pair[2];CHECK(socketpair(AF_INET,SOCK_STREAM,0,pair)==-1 && errno==EPERM);
  CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,pair));close(pair[0]);close(pair[1]);
  int unixfd=socket(AF_UNIX,SOCK_STREAM,0);CHECK(unixfd>=0);close(unixfd);
  for(int i=5;i<256;i++)CHECK(fcntl(i,F_GETFD)==-1 && errno==EBADF);
  CHECK(!getenv("N6_OWNER_PASSWORD_HASH")&&!getenv("HTTP_PROXY")&&!getenv("ISO_OUTBOUND_POLICY"));
  /* Children intentionally survive their immediate parent: root controller must reap the group. */
  int count=0;for(;count<40;count++) {pid_t pid=fork();if(pid<0){CHECK(errno==EAGAIN);break;}if(!pid){for(;;)pause();}}
  CHECK(count>0 && count<32);
  int lifetime=strstr(argv[1],"lifetime")!=NULL;
  printf("{\"type\":\"success\",\"answers\":[\"checks_passed\"],\"more\":%s}\n",lifetime?"true":"false");fflush(stdout);
  if(lifetime){char c;while(read(0,&c,1)>0){}}return 0;
}
