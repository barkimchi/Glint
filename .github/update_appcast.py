import re, sys

tag, sigline, pubdate = sys.argv[1], sys.argv[2], sys.argv[3]
version = tag.lstrip('v')
m = re.search(r'sparkle:edSignature="([^"]+)"\s+length="([^"]+)"', sigline)
if not m:
    sys.exit('could not parse sign_update output: ' + sigline)
sig, length = m.group(1), m.group(2)
build = str(int(round(float(version.split('.')[-1])))) if False else None
# build number: CFBundleVersion is bumped per release; read it from project.yml
proj = open('project.yml').read()
build = re.search(r'CFBundleVersion:\s*"([^"]+)"', proj).group(1)
item = f'''    <item>
      <title>Glint {version}</title>
      <link>https://github.com/barkimchi/glint-app/releases/tag/{tag}</link>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:releaseNotesLink>https://github.com/barkimchi/glint-app/releases/tag/{tag}</sparkle:releaseNotesLink>
      <pubDate>{pubdate}</pubDate>
      <enclosure url="https://github.com/barkimchi/glint-app/releases/download/{tag}/Glint.zip"
                 sparkle:edSignature="{sig}"
                 length="{length}"
                 type="application/octet-stream" />
    </item>
'''
s = open('appcast.xml').read()
assert '  </channel>' in s
s = s.replace('  </channel>', item + '  </channel>', 1)
open('appcast.xml','w').write(s)
print('appcast updated for', tag, 'build', build)
