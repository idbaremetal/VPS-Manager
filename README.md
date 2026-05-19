# VPS Manager

`VPS Manager` adalah panel manager VPS untuk Proxmox VE (`PVE`) yang dikhususkan untuk pelanggan [IDBaremetal](https://idbaremetal.com). Aplikasi ini dibuat untuk mempermudah pengelolaan VPS, otomasi NAT, dan integrasi dengan billing system agar provisioning dan management instance menjadi lebih praktis.

## Fitur Utama

- Management VPS di node Proxmox VE
- Login menggunakan PAM Linux dan JWT session
- Management token untuk integrasi service-to-service
- Alokasi private IP otomatis
- NAT manager dengan penyimpanan rule persisten
- Katalog template VM dan LXC
- Cocok untuk diintegrasikan dengan billing system internal

## Instalasi Cepat

Installer akan:

- mendownload binary `vpsmanager` dari GitHub
- membuat bridge `vmbr1` jika belum ada
- menambahkan bridge ke `/etc/network/interfaces`
- apply network dengan `ifreload -a`
- membuat file konfigurasi default di `/etc/vpsmanager`
- membuat service `systemd` bernama `vpsmanager.service`
- menjalankan service secara otomatis

Jalankan perintah berikut sebagai `root` di server Proxmox VE:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/idbaremetal/VPS-Manager/refs/heads/main/Install.sh)"
```

Jika lebih nyaman memakai `wget`:

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/idbaremetal/VPS-Manager/refs/heads/main/Install.sh)"
```

## Default Konfigurasi Installer

Installer akan langsung memakai nilai default berikut:

- listen host: `0.0.0.0`
- port: `8005`
- NAT port range: `10000` sampai `30000`
- private bridge: `vmbr1`
- private gateway: `10.0.0.1`
- private subnet: `10.0.0.0/22`
- private IP pool: `10.0.1.1` sampai `10.0.3.254`
- default storage: `local`
- storage type: `file_system`
- LXC template storage: `local`
- VM template directory: `/var/lib/vz/template/iso`

Nilai `public_ip` dan `node_name` akan dideteksi otomatis saat instalasi.

## Lokasi File Penting

- binary: `/usr/local/bin/vpsmanager`
- config utama: `/etc/vpsmanager/app-settings.json`
- private IP state: `/etc/vpsmanager/private-ip-allocations.json`
- NAT rules state: `/etc/vpsmanager/nat-rules.json`
- VM template state: `/etc/vpsmanager/vm-template-state.json`
- systemd service: `/etc/systemd/system/vpsmanager.service`

## Akses Setelah Install

Secara default aplikasi listen di `0.0.0.0:8005`, jadi akses dilakukan melalui IP publik server:

- docs: `http://IP_PUBLIK:8005/docs`
- health: `http://IP_PUBLIK:8005/healthz`

## Perintah Dasar Service

```bash
systemctl status vpsmanager
journalctl -u vpsmanager -f
systemctl restart vpsmanager
```

## Catatan

- Installer ini ditujukan untuk Linux server yang menjalankan Proxmox VE
- Disarankan menjalankan installer langsung di node PVE
- Karena aplikasi ini ditujukan untuk ekosistem pelanggan IDBaremetal, penyesuaian lebih lanjut untuk billing system bisa dilakukan sesuai kebutuhan internal
