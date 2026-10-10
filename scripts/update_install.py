import subprocess,time,re,xml.etree.ElementTree as ET,pathlib,json
OUT=pathlib.Path('update-evidence'); OUT.mkdir(exist_ok=True)
PKG='com.wkddkw.cliproxy_quota'
def adb(*args,check=True):
 return subprocess.run(['adb',*args],check=check,stdout=subprocess.PIPE,stderr=subprocess.STDOUT).stdout.decode(errors='replace')
def capture(label):
 adb('shell','uiautomator','dump','/sdcard/window.xml',check=False)
 xml=adb('shell','cat','/sdcard/window.xml',check=False)
 (OUT/(label+'.xml')).write_text(xml)
 print('UI_CAPTURE',label,xml,flush=True)
 with (OUT/(label+'.png')).open('wb') as f: subprocess.run(['adb','exec-out','screencap','-p'],stdout=f,check=False)
 return xml
def nodes():
 adb('shell','uiautomator','dump','/sdcard/window.xml',check=False)
 try:return list(ET.fromstring(adb('shell','cat','/sdcard/window.xml')).iter('node'))
 except: return []
def click_text(text,scroll=False,timeout=45):
 end=time.time()+timeout
 while time.time()<end:
  for n in nodes():
   if text in (n.get('text','')+' '+n.get('content-desc','')):
    coords=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
    if len(coords)==4 and coords[2]>coords[0] and coords[3]>coords[1]:
     adb('shell','input','tap',str((coords[0]+coords[2])//2),str((coords[1]+coords[3])//2));time.sleep(2);return
  if scroll:adb('shell','input','swipe','500','1800','500','600','350')
  time.sleep(1)
 capture('missing-'+text);raise RuntimeError('UI text not found: '+text)
def version():
 s=adb('shell','dumpsys','package',PKG)
 return re.search(r'versionName=([^\s]+)',s).group(1)
def launch():adb('shell','am','start','-n',PKG+'/.MainActivity');time.sleep(4)
try:
 adb('install','old.apk');assert version()=='0.1.10'
 # Only the isolated CI emulator is changed; no user's device or data is involved.
 adb('shell','appops','set',PKG,'REQUEST_INSTALL_PACKAGES','allow')
 launch();capture('01-old-installed')
 click_text('检查更新',scroll=True,timeout=75)
 time.sleep(5);capture('02-update-offer')
 click_text('下载更新',timeout=45)
 time.sleep(5)
 # The app downloads from its real GitHub release URL and opens its FileProvider URI.
 end=time.time()+180;installer=False
 while time.time()<end:
  current=adb('shell','dumpsys','activity','activities')
  if any(x in current for x in ['mResumedActivity: ActivityRecord','topResumedActivity']):
   lines=[x for x in current.splitlines() if 'ResumedActivity' in x]
   if any('packageinstaller' in x.lower() or 'permissioncontroller' in x.lower() for x in lines):installer=True;break
  time.sleep(3)
 capture('03-system-installer')
 (OUT/'activity.txt').write_text(adb('shell','dumpsys','activity','activities'))
 if not installer:raise RuntimeError('System installer did not open within download window')
 # Android image uses English. Only click the explicit install/update confirmation.
 ns=nodes();label=next((n.get('text') for n in ns if n.get('text','').upper() in ['INSTALL','UPDATE']),None)
 if not label:raise RuntimeError('No system INSTALL/UPDATE confirmation; inspect screenshot')
 click_text(label,timeout=20)
 end=time.time()+90
 while time.time()<end and version()!='0.1.11':time.sleep(2)
 capture('04-install-result');assert version()=='0.1.11',version()
 print('INSTALLED_VERSION_CONFIRMED',version(),flush=True)
 click_text('Open',timeout=30);time.sleep(5)
 capture('05-reopened')
 click_text('检查更新',scroll=True,timeout=75);capture('06-new-current-version')
 assert version()=='0.1.11'
 (OUT/'result.json').write_text(json.dumps({'initial':'0.1.10','installed':'0.1.11','route':'real released APK -> app update -> DownloadManager -> FileProvider -> system confirmation','next_upgrade_tested':False}))
 print('REAL_UPDATE_INSTALL_PASS 0.1.10 -> 0.1.11')
finally:
 capture('final');(OUT/'package.txt').write_text(adb('shell','dumpsys','package',PKG,check=False));(OUT/'logcat.txt').write_text(adb('logcat','-d',check=False))
