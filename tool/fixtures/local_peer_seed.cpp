// Original-fixture loopback seeder for BitTorrent-wire acceptance tests.
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/peer_class.hpp>
#include <chrono>
#include <iostream>
#include <memory>
#include <string>
#include <stdexcept>
#include <thread>

int main(int argc, char** argv) {
  if (argc != 3) return 2;
  try {
    namespace lt = libtorrent;
    lt::settings_pack settings;
    settings.set_str(lt::settings_pack::listen_interfaces, "127.0.0.1:0");
    settings.set_bool(lt::settings_pack::enable_dht, false);
    settings.set_bool(lt::settings_pack::enable_lsd, false);
    settings.set_bool(lt::settings_pack::enable_upnp, false);
    settings.set_bool(lt::settings_pack::enable_natpmp, false);
    settings.set_int(lt::settings_pack::upload_rate_limit, 1024 * 1024);
    lt::session session(settings);
    // Loopback peers have a separate class and may bypass global limits.
    auto local = session.get_peer_class(lt::session::local_peer_class_id);
    local.upload_limit = 1024 * 1024;
    session.set_peer_class(lt::session::local_peer_class_id, local);
    lt::add_torrent_params params;
    params.ti = std::make_shared<lt::torrent_info>(argv[1]);
    params.save_path = argv[2];
    params.flags |= lt::torrent_flags::seed_mode;
    params.flags &= ~lt::torrent_flags::paused;
    params.flags &= ~lt::torrent_flags::auto_managed;
    session.add_torrent(params);
    for (int n = 0; n < 100 && !session.listen_port(); ++n)
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
    if (!session.listen_port()) throw std::runtime_error("No loopback listener");
    std::cout << lt::make_magnet_uri(params) << "&x.pe=127.0.0.1:"
              << session.listen_port() << std::endl;
    // The private parent pipe owns lifetime; no daemon survives host exit.
    std::string line;
    std::getline(std::cin, line);
  } catch (const std::exception& error) {
    std::cerr << error.what() << std::endl;
    return 1;
  }
}
