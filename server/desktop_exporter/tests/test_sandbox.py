"""Real kernel enforcement tests; all fixtures are synthetic and temporary."""
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

from test_desktop_export import seed, write

PACKAGE=Path(__file__).resolve().parents[1]
LAUNCHER=PACKAGE/'lcp-export-sandbox'
HELPER=PACKAGE/'tests/fail-syscall'
def manifest(root):
    return {str(p.relative_to(root)):(hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() and not p.is_symlink() else None,
        p.lstat().st_mode,p.lstat().st_ino,p.lstat().st_nlink,p.lstat().st_size,
        p.lstat().st_mtime_ns,p.lstat().st_ctime_ns)
        for p in sorted(root.rglob('*'))}

@unittest.skipUnless(platform.system()=='Linux' and platform.machine()=='x86_64' and LAUNCHER.exists(),
                     'Linux x86_64 native sandbox required; never a deployment waiver')
class SandboxTests(unittest.TestCase):
    def setUp(self):
        self.old_umask=os.umask(0o077)
        self.addCleanup(os.umask,self.old_umask)
        temp=tempfile.TemporaryDirectory(prefix='lcp-SYNTHETIC-sandbox-')
        self.addCleanup(temp.cleanup)
        self.base=Path(temp.name)
        self.source=self.base/'source';self.source.mkdir(mode=0o700)
        self.output=self.base/'feed';self.output.mkdir(mode=0o700)
        self.outside=self.base/'outside';self.outside.mkdir(mode=0o700)
        seed(self.source)
        (self.source/'empty').mkdir(mode=0o700)
        for name in ['archive','work','vault','classes']:
            (self.source/name).mkdir(mode=0o700)
            (self.source/name/'private').write_text('SYNTHETIC SECRET')
        (self.source/'state/worker.lock').write_text('SYNTHETIC LOCK')
        (self.source/'inbox/audio.m4a').write_bytes(b'SYNTHETIC NOT AUDIO')
        (self.source/'alias-heads').symlink_to('state/heads.json')
        (self.source/'alias-state').symlink_to('state',target_is_directory=True)
        (self.outside/'canary').write_text('SYNTHETIC OUTSIDE')
        self.before=manifest(self.source)
        self.outside_before=manifest(self.outside)
    def command(self,code=None):
        tail=['-c',code] if code else ['-B',str(PACKAGE/'run_export.py'),
            '--source-root',str(self.source),'--output-root',str(self.output)]
        return [str(LAUNCHER),str(PACKAGE),str(self.source),str(self.output),'--','/usr/bin/python3','-I','-S',*tail]
    def run_process(self,command,**kwargs):
        return subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=20,**kwargs)
    def preserved(self):
        self.assertEqual(self.before,manifest(self.source))
        self.assertEqual(self.outside_before,manifest(self.outside))
    def test_kernel_write_escape_metadata_and_ipc_denials(self):
        fd=os.open(self.source/'state/heads.json',os.O_RDWR)
        high=198;os.dup2(fd,high,inheritable=True)
        try:
            cmd=self.command("import runpy,sys;sys.argv="+repr(['probe',str(self.source),str(self.output),str(self.outside),str(PACKAGE),str(high)])+";runpy.run_path("+repr(str(PACKAGE/'tests/sandbox_probe.py'))+",run_name='__main__')")
            result=self.run_process(cmd,pass_fds=(high,),stdin=fd)
            self.assertEqual(result.returncode,0,result.stderr)
            data=json.loads(result.stdout);self.assertGreaterEqual(len(data['denied']),45)
            self.preserved()
        finally:
            os.close(fd);os.close(high)
    def test_real_export_repeated_under_kernel_boundary(self):
        for _ in range(2):
            result=self.run_process(self.command())
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout)['transcripts'],1)
        index=json.loads((self.output/'index.json').read_bytes())
        for row in index['recordings']:
            ref=row['transcript']
            if ref:
                raw=(self.output/ref['path']).read_bytes()
                self.assertEqual(len(raw),ref['size_bytes'])
                self.assertEqual(hashlib.sha256(raw).hexdigest(),ref['sha256'])
        for p in [self.output,*self.output.rglob('*')]:
            self.assertEqual(p.stat().st_mode & 0o077,0)
        self.preserved()
    def test_four_recording_fixture_eligibility(self):
        heads={}
        for label in ['Eligible','Blocked','Missing','Unaccepted']:
            name=f'SYNTHETIC {label}_2026-11-19_1200.m4a';job='synthetic-'+label
            _,head,state=seed(self.source,name=name,job=job)
            if label!='Unaccepted':heads[name]=head
            if label=='Blocked':
                state['publication_blocked']=True;state['stage']='quality_blocked'
                write(self.source/'state/jobs'/f'{job}.json',state)
            if label=='Missing':(self.source/'state/jobs'/f'{job}.json').unlink()
        # Remove the initial fixture's marker and reset the combined head map.
        (self.source/'inbox/SYNTHETIC Demo_2026-11-19_1200.m4a.ready.json').unlink()
        write(self.source/'state/heads.json',heads);self.before=manifest(self.source)
        result=self.run_process(self.command());self.assertEqual(result.returncode,0,result.stderr)
        rows=json.loads((self.output/'index.json').read_bytes())['recordings']
        self.assertEqual(len(rows),4)
        self.assertEqual([r['filename'].split('_')[0] for r in rows if r['transcript']],['SYNTHETIC Eligible'])
        self.preserved()
    def test_unavailable_required_kernel_primitives_reject_before_python(self):
        for nr,arg,label in [(444,0,'landlock'),(446,4294967295,'landlock_restrict'),
                             (157,22,'seccomp'),(436,3,'close_range')]:
            with self.subTest(label=label):
                result=self.run_process([str(HELPER),str(nr),str(arg),*self.command("open("+repr(str(self.output/'ran'))+",'w').write('BAD')")])
                self.assertEqual(result.returncode,126,result.stderr)
                self.assertIn('desktop_sandbox_rejected:',result.stderr)
                self.assertFalse((self.output/'ran').exists())
        self.preserved()
    def test_inherited_stdout_and_stderr_source_files_never_written(self):
        for standard in ['stdout','stderr','unavailable_stderr']:
            fd=os.open(self.source/'state/heads.json',os.O_RDWR)
            try:
                args={'stdout':subprocess.PIPE,'stderr':subprocess.PIPE,
                      'stderr' if standard=='unavailable_stderr' else standard:fd}
                cmd=self.command("print('BAD')")
                if standard=='unavailable_stderr':cmd=[str(HELPER),'436','3',*cmd]
                result=subprocess.run(cmd,text=True,timeout=20,**args)
                self.assertEqual(result.returncode,126)
                self.preserved()
            finally:os.close(fd)
    def test_existing_output_hardlink_and_symlink_rejected(self):
        for kind in ['hardlink','symlink']:
            target=self.output/'alias'
            if kind=='hardlink':os.link(self.source/'state/heads.json',target)
            else:target.symlink_to(self.source/'state/heads.json')
            result=self.run_process(self.command("print('BAD')"))
            self.assertEqual(result.returncode,126,result.stderr)
            target.unlink()
        # Link creation/removal was performed by this synthetic test parent.
        self.assertEqual(hashlib.sha256((self.source/'state/heads.json').read_bytes()).hexdigest(),
                         self.before['state/heads.json'][0])
        self.assertEqual((self.source/'state/heads.json').stat().st_nlink,1)
    def test_symlink_and_overlapping_roots_rejected(self):
        alias=self.base/'source-alias';alias.symlink_to(self.source,target_is_directory=True)
        for source,output in [(alias,self.output),(self.source,self.source),(self.source,self.source/'empty')]:
            cmd=self.command("print('BAD')");cmd[2]=str(source);cmd[3]=str(output)
            result=self.run_process(cmd);self.assertEqual(result.returncode,126,result.stderr)
        self.preserved()
