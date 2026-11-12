project(
    'ytws-preview',
    'c',
    version: '1',
    meson_version: '>=0.60',
    default_options: ['c_std=c11', 'warning_level=3', 'buildtype=release'],
)

wayland_client = dependency('wayland-client')
wayland_protocols = dependency('wayland-protocols', version: '>=1.37')
wayland_scanner = find_program(
    dependency('wayland-scanner', native: true).get_variable(pkgconfig: 'wayland_scanner'),
)
gbm = dependency('gbm', version: '>=21.3')
libdrm = dependency('libdrm', version: '>=2.4.110')

protocols_dir = wayland_protocols.get_variable(pkgconfig: 'pkgdatadir')
protocols = [
    # Referenced by ext-image-capture-source, though only outputs are captured.
    'staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml',
    'staging/ext-image-capture-source/ext-image-capture-source-v1.xml',
    'staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml',
    'staging/single-pixel-buffer/single-pixel-buffer-v1.xml',
    'stable/linux-dmabuf/linux-dmabuf-v1.xml',
    'stable/viewporter/viewporter.xml',
    'stable/xdg-shell/xdg-shell.xml',
]

sources = ['preview.c']
foreach protocol : protocols
    xml = protocols_dir / protocol
    sources += custom_target(
        input: xml,
        output: '@BASENAME@-client-protocol.h',
        command: [wayland_scanner, 'client-header', '@INPUT@', '@OUTPUT@'],
    )
    sources += custom_target(
        input: xml,
        output: '@BASENAME@-protocol.c',
        command: [wayland_scanner, 'private-code', '@INPUT@', '@OUTPUT@'],
    )
endforeach

executable('ytws-preview', sources, dependencies: [wayland_client, gbm, libdrm])
