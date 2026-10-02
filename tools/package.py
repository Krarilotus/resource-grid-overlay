"""Pack module/ into dist/<name>-<version>.zip, the file a release is uploaded with.

UCP reads `name-version` from the zip's own name and expects the module's files at the root
of the archive, exactly as the shipped modules do - no folder in between. The version comes
from definition.yml, so the zip can never disagree with what it contains.

    python tools/package.py
"""
import io, os, re, zipfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE = os.path.join(HERE, 'module')
DIST = os.path.join(HERE, 'dist')
NAME = 'resource-grid-overlay'


def read_version():
    with io.open(os.path.join(MODULE, 'definition.yml'), encoding='utf-8') as f:
        text = f.read()
    declared = re.search(r'^name:\s*(\S+)', text, re.M).group(1)
    if declared != NAME:
        raise SystemExit('definition.yml says name: %s, not %s' % (declared, NAME))
    return re.search(r'^version:\s*(\S+)', text, re.M).group(1)


def main():
    version = read_version()
    os.makedirs(DIST, exist_ok=True)
    target = os.path.join(DIST, '%s-%s.zip' % (NAME, version))

    files = []
    for root, _, names in os.walk(MODULE):
        for name in sorted(names):
            path = os.path.join(root, name)
            files.append((path, os.path.relpath(path, MODULE).replace(os.sep, '/')))
    files.sort(key=lambda pair: pair[1])

    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as z:
        for folder in sorted({os.path.dirname(rel) for _, rel in files} - {''}):
            z.writestr(zipfile.ZipInfo(folder + '/'), '')
        for path, rel in files:
            z.write(path, rel)

    # Read it back: a module that unpacks to anything but what is in module/ is worse than
    # no module at all, and the GUI will not tell you which file went wrong.
    with zipfile.ZipFile(target) as z:
        if z.testzip() is not None:
            raise SystemExit('bad zip: ' + target)
        for path, rel in files:
            if z.read(rel) != open(path, 'rb').read():
                raise SystemExit('zip differs from module/: ' + rel)

    print('%s  %d bytes  %s' % (os.path.basename(target), os.path.getsize(target),
                                ', '.join(rel for _, rel in files)))
    print('upload it with: gh release create v%s dist/%s-%s.zip' % (version, NAME, version))


if __name__ == '__main__':
    main()
