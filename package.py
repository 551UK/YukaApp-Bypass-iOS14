import io, pathlib, plistlib, tarfile
root = pathlib.Path(__file__).resolve().parent

def archive(files):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode='w:gz', format=tarfile.USTAR_FORMAT) as tar:
        for name, data, mode in files:
            item = tarfile.TarInfo(name)
            item.size = len(data)
            item.mode = mode
            item.uid = item.gid = 0
            item.uname = item.gname = 'root'
            tar.addfile(item, io.BytesIO(data))
    return out.getvalue()

control = archive([('./control', (root/'control').read_bytes(), 0o644)])
prefix = './Library/MobileSubstrate/DynamicLibraries/'
data = archive([(prefix+'YukaBypass.dylib', (root/'build/YukaBypass.dylib').read_bytes(), 0o755),
                (prefix+'YukaBypass.plist', plistlib.dumps({'Filter': {'Bundles': ['yuca.scanner']}}), 0o644)])
package = root/'packages/com.551uk.yukabypass14_1.0.3_iphoneos-arm.deb'
with package.open('wb') as out:
    out.write(b'!<arch>\n')
    for name, content in [('debian-binary', b'2.0\n'), ('control.tar.gz', control), ('data.tar.gz', data)]:
        header = f'{name+"/":<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(content):<10}`\n'
        assert len(header) == 60
        out.write(header.encode('ascii')); out.write(content)
        if len(content) % 2: out.write(b'\n')
print(package)
