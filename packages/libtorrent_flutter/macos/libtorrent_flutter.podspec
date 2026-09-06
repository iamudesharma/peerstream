Pod::Spec.new do |s|
  s.name             = 'libtorrent_flutter'
  s.version          = '1.7.0'
  s.summary          = 'Flutter plugin for libtorrent with built-in streaming server.'
  s.description      = <<-DESC
  Native libtorrent 2.0 bindings for Flutter with an integrated HTTP streaming server.
                       DESC
  s.homepage         = 'https://github.com/ayman708-UX/libtorrent_flutter'
  s.license          = { :type => 'GPL-3.0', :file => '../LICENSE' }
  s.author           = { 'ayman708-UX' => 'ayman@example.com' }
  s.source           = { :path => '.' }

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.14'
  s.osx.deployment_target = '10.14'
  s.swift_version = '5.0'

  # The application vendors this package to build the streaming engine from
  # source. A prebuilt bridge makes it impossible to verify which native
  # streaming implementation is actually running.
  s.source_files = 'Classes/**/*'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/../src"',
      '"/opt/homebrew/include"',
      '"/usr/local/include"',
    ].join(' '),
    'LIBRARY_SEARCH_PATHS' => [
      '"/opt/homebrew/lib"',
      '"/usr/local/lib"',
    ].join(' '),
    'OTHER_LDFLAGS' => '-ltorrent-rasterbar -lboost_system -lssl -lcrypto',
    # Keep the bridge ABI-aligned with the libtorrent binary supplied by
    # Homebrew. These are the package's published consumer flags.
    'OTHER_CPLUSPLUSFLAGS' => '-std=c++17 -DTORRENT_BRIDGE_EXPORTS -DTORRENT_NO_DEPRECATE -DTORRENT_LINKING_SHARED -DBOOST_ASIO_ENABLE_CANCELIO -DBOOST_ASIO_NO_DEPRECATED -DBOOST_SYSTEM_USE_UTF8 -D_SILENCE_CXX17_ALLOCATOR_VOID_DEPRECATION_WARNING -DTORRENT_ABI_VERSION=2 -DTORRENT_USE_OPENSSL -DTORRENT_USE_LIBCRYPTO -DTORRENT_SSL_PEERS -DOPENSSL_NO_SSL2 -DOPENSSL_NO_SSL3 -DOPENSSL_NO_TLS1 -DOPENSSL_NO_TLS1_1 -DOPENSSL_NO_DTLS1',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
  }
end
