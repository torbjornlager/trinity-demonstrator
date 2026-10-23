import os,subprocess,json,time,signal
from pathlib import Path
OUT=Path(__file__).resolve().parent
BASE=Path('/Users/torbjorn.lager/.local/share/trinity-runtime-tests')
OLD=BASE/'swipl-09b6299';NEW=BASE/'swipl-09b6299-pcre-2026-10-23'
TOOLS=OLD/'build-tools/bin';CMAKE=str(TOOLS/'cmake');SDK='/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk'
ENV=dict(os.environ,PATH=str(TOOLS)+':'+os.environ['PATH'],SDKROOT=SDK)
results=[]
def run(label,cmd,cwd=None,timeout=600):
 start=time.time();print('START',label,flush=True)
 with (OUT/(label+'.log')).open('w') as log:
  p=subprocess.Popen([str(x) for x in cmd],cwd=cwd,env=ENV,stdout=log,stderr=log,start_new_session=True)
  try:rc=p.wait(timeout=timeout)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait();rc='watchdog_timeout'
 results.append(dict(label=label,command=[str(x) for x in cmd],cwd=str(cwd) if cwd else None,exit_code=rc,seconds=round(time.time()-start,3)))
 (OUT/'build-results.json').write_text(json.dumps(results,indent=2)+'\n');print('END',label,rc,flush=True)
 if rc!=0:raise SystemExit(1)
run('clone-swi',['git','clone','--no-hardlinks',OLD/'source',NEW/'source'])
run('swi-origin',['git','-C',NEW/'source','remote','set-url','origin','https://github.com/SWI-Prolog/swipl-devel.git'])
packages=['clib','plunit','http','sgml','json','ssl','zlib','utf8proc']
cmd=['git','-c','protocol.file.allow=always']
for pkg in packages:cmd+=['-c',f'submodule.packages/{pkg}.url={OLD}/source/packages/{pkg}']
cmd+=['submodule','update','--init','--jobs','4']+['packages/'+p for p in packages+['pcre']]
run('swi-submodules',cmd,NEW/'source')
run('clone-pcre2',['git','clone','--depth','1','--branch','pcre2-10.49','--recurse-submodules','--shallow-submodules','https://github.com/PCRE2Project/pcre2.git',NEW/'pcre2-source'])
run('configure-pcre2',[CMAKE,'-S',NEW/'pcre2-source','-B',NEW/'pcre2-build','-G','Ninja','-DCMAKE_BUILD_TYPE=Release',f'-DCMAKE_OSX_SYSROOT={SDK}',f'-DCMAKE_INSTALL_PREFIX={NEW}/pcre2','-DCMAKE_POSITION_INDEPENDENT_CODE=ON','-DBUILD_SHARED_LIBS=OFF','-DPCRE2_BUILD_PCRE2_8=ON','-DPCRE2_BUILD_PCRE2_16=OFF','-DPCRE2_BUILD_PCRE2_32=OFF','-DPCRE2_SUPPORT_UNICODE=ON','-DPCRE2_SUPPORT_JIT=ON','-DPCRE2_BUILD_TESTS=ON'])
run('build-pcre2',[CMAKE,'--build',NEW/'pcre2-build','--parallel','4'])
run('test-pcre2',[TOOLS/'ctest','--test-dir',NEW/'pcre2-build','--output-on-failure','--timeout','120'])
run('install-private-pcre2',[CMAKE,'--install',NEW/'pcre2-build'])
run('configure-swi',[CMAKE,'-S',NEW/'source','-B',NEW/'build','-G','Ninja','-DCMAKE_BUILD_TYPE=Release',f'-DCMAKE_OSX_SYSROOT={SDK}',f'-DCMAKE_INSTALL_PREFIX={NEW}/install','-DSWIPL_PACKAGE_LIST=clib;plunit;http;sgml;json;pcre','-DSWIPL_PACKAGES_SSL=OFF','-DUSE_GMP=OFF','-DUSE_LIBBF=ON','-DINSTALL_DOCUMENTATION=OFF',f'-DOPENSSL_ROOT_DIR={OLD}/openssl','-DOPENSSL_USE_STATIC_LIBS=TRUE',f'-DPCRE_INCLUDE_DIR={NEW}/pcre2/include',f'-DPCRE_LIBRARY={NEW}/pcre2/lib/libpcre2-8.a'])
run('build-swi',[CMAKE,'--build',NEW/'build','--parallel','4'])
print('BUILD COMPLETE',flush=True)
