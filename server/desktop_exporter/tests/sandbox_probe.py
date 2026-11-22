"""Adversarial probe. All paths MUST be isolated synthetic staging paths."""
import ctypes
import errno
import json
import mmap
import os
from pathlib import Path
import socket
import sys

source, output, outside, package = map(Path, sys.argv[1:5])
assert 'SYNTHETIC' in str(source) and '/data/' not in str(source)
canary = source / 'state/heads.json'
libc=ctypes.CDLL(None, use_errno=True)
results={}
def denied(label, operation, codes=(errno.EPERM, errno.EACCES, errno.EROFS, errno.EXDEV)):
    try:
        value=operation()
    except OSError as error:
        assert error.errno in codes, (label,error)
        results[label]=error.errno
    else:
        if isinstance(value,int):
            os.close(value)
        raise AssertionError('sandbox escape: '+label)

assert canary.read_bytes()
for parent,label in [(source,'source'),(outside,'outside'),(package,'package')]:
    denied(label+'_create',lambda parent=parent: os.open(parent/'created',os.O_WRONLY|os.O_CREAT,0o600))
denied('write',lambda: os.open(canary,os.O_WRONLY))
denied('read_write',lambda: os.open(canary,os.O_RDWR))
denied('open_truncate',lambda: os.open(canary,os.O_RDONLY|os.O_TRUNC))
denied('truncate',lambda: os.truncate(canary,0))
fd=os.open(canary,os.O_RDONLY)
denied('ftruncate',lambda: os.ftruncate(fd,0), (errno.EPERM,errno.EACCES,errno.EROFS,errno.EINVAL))
denied('shared_writable_mmap',lambda: mmap.mmap(fd,0,flags=mmap.MAP_SHARED,prot=mmap.PROT_WRITE))
denied('fchmod',lambda: os.fchmod(fd,0o777))
os.close(fd)
denied('mkdir',lambda: os.mkdir(source/'new-dir'))
denied('unlink',lambda: os.unlink(canary))
denied('rmdir',lambda: os.rmdir(source/'empty'))
denied('rename_inside_source',lambda: os.rename(canary,source/'state/renamed.json'))
denied('rename_source_to_output',lambda: os.rename(canary,output/'stolen'))
denied('link_source_to_output',lambda: os.link(canary,output/'hardlink'))
denied('link_inside_source',lambda: os.link(canary,source/'state/hardlink'))
denied('symlink_source',lambda: os.symlink('heads.json',source/'state/symlink'))
denied('symlink_output',lambda: os.symlink(canary,output/'symlink'))
denied('chmod',lambda: os.chmod(canary,0o777))
denied('chown',lambda: os.chown(canary,os.getuid(),os.getgid()))
denied('utime',lambda: os.utime(canary,ns=(1,1)))
denied('xattr',lambda: os.setxattr(canary,'user.sandbox',b'changed'))
denied('parent_traversal',lambda: os.open(output/os.path.relpath(canary,output),os.O_WRONLY))
os.chdir(source)
denied('cwd_relative',lambda: os.open('state/heads.json',os.O_WRONLY))
source_fd=os.open(source,os.O_PATH|os.O_DIRECTORY)
denied('openat_source_directory',lambda: os.open('created',os.O_WRONLY|os.O_CREAT,0o600,dir_fd=source_fd))
os.close(source_fd)
denied('preexisting_source_symlink',lambda: os.open(source/'alias-heads',os.O_WRONLY))
denied('preexisting_parent_symlink',lambda: os.open(source/'alias-state/heads.json',os.O_WRONLY))
denied('absolute_outside',lambda: os.open(outside/'canary',os.O_WRONLY))
denied('proc_fd_reopen',lambda: os.open('/proc/self/fd/0',os.O_RDWR))
denied('proc_parent_fd',lambda: os.open('/proc/%d/fd/0'%os.getppid(),os.O_RDWR))
for relative in ['state/provider-control.json','state/stt-retry-limits.json','state/worker.lock',
                 'archive/private','work/private','vault/private','classes/private','inbox/audio.m4a']:
    denied('read_denied_'+relative,lambda relative=relative: os.open(source/relative,os.O_RDONLY))
for folder in ['archive','work','vault','classes']:
    denied('list_denied_'+folder,lambda folder=folder: os.listdir(source/folder))
for family in [socket.AF_UNIX,socket.AF_INET,socket.AF_INET6]:
    denied('network_'+str(family),lambda family=family: socket.socket(family,socket.SOCK_STREAM))
for number,label in [(425,'io_uring_setup'),(438,'pidfd_getfd'),(101,'ptrace'),(311,'process_vm_writev')]:
    ctypes.set_errno(0)
    assert libc.syscall(number,0,0,0,0,0,0)==-1 and ctypes.get_errno()==errno.EPERM,label
    results[label]=errno.EPERM
# All descriptors passed in from the parent must have been closed. Explicitly
# try pwrite and ftruncate, including a source fd inherited as stdin (fd 0).
for number in [0]+[int(v) for v in sys.argv[5:]]:
    denied('inherited_write_'+str(number),lambda number=number: os.pwrite(number,b'ESCAPE',0),
           (errno.EBADF,errno.EINVAL,errno.EPERM,errno.EACCES))
    denied('inherited_truncate_'+str(number),lambda number=number: os.ftruncate(number,0),
           (errno.EBADF,errno.EINVAL,errno.EPERM,errno.EACCES))
# Allowed operations exercise actual exporter durability requirements.
first=output/'allowed'; first.write_bytes(b'SYNTHETIC')
denied('rename_output_into_source',lambda: os.rename(first,source/'state/overwrite'))
ctypes.set_errno(0)
assert libc.syscall(316,-100,os.fsencode(first),-100,os.fsencode(canary),2)==-1
assert ctypes.get_errno() in (errno.EPERM,errno.EACCES,errno.EROFS,errno.EXDEV)
results['rename_exchange']=ctypes.get_errno()
os.truncate(first,4)
sub=output/'sub'; sub.mkdir(mode=0o700)
os.link(first,sub/'linked'); os.unlink(sub/'linked')
os.rename(first,sub/'renamed'); (sub/'renamed').unlink(); sub.rmdir()
print(json.dumps({'denied':results,'output_operations_passed':True},sort_keys=True))
