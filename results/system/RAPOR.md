# Bütün sistemin yerel doğrulaması

Tarih: 2026-10-31 (Türkiye saati).

| Katman | Gerçekleştirilen kontrol | Sonuç |
| --- | --- | --- |
| Hesap/kontrol/stream RTL | Dört boyutta doğruluk, AXI-Lite ve reset testleri | PASS |
| E1 bellek yeniden kullanımı | 36 koşu, 12 eşleştirilmiş koşul | PASS |
| E2 eski stream | Dört boyut × üç politika = 12 koşu | PASS |
| C kullanıcı aracı | Mac ve ARM64 Linux derlemesi; ABI, signed referans, endian ve reuse sözleşmesi | PASS |
| Python araçları | 7 test: deney geçişleri, kaçırılan pencere/başarısız rapor kayıtları, paket reddi, Tcl sözdizimi, sabitler | PASS |
| Linux kernel modülü | ARM64 Linux 6.12.113+deb13; W=1 ve KCFLAGS=-Werror | PASS |
| Device tree | dtc, fdtoverlay test ağacı, adres/IRQ kontrolleri | PASS |
| Vivado/IP/bitstream | Araç erişimi olmadığı için çalıştırılmadı | DOĞRULANMADI |
| Yocto/EDF/PetaLinux imajı | Tarifler eklendi, imaj derlenmedi | DOĞRULANMADI |
| Gerçek KV260/DDR/sürücü | Karta erişim olmadığı için çalıştırılmadı | DOĞRULANMADI |

RTL matrisinde 18 PASS satırı var. E1'de P0/P1 eski yazılara izin verirken P2 boşaltmayı bekledi. E2'de B kimlikli descriptor, kaynaktaki A verisini P0/P1'de kabul etti; 64×64 için 64 eski sözcük gözlendi. P2 önce A'yı boşaltıp gerçek B hesabını doğru tamamladı. Bunlar sınırlı S2MM/RAM modeli sonuçlarıdır; gerçek AMD DMA açığı iddiası değildir.

Kernel modülü gerçek başlıklarla derlendi; yüklenmedi. DMA callback, cache/DDR, hata ve kaldırma yolları kartta henüz sınanmadı. DT testi boot edilebilir kart ağacı yerine fixture kullandı. Tcl için yalnız sözdizimi kontrolü yapıldı; Vivado komut/IP uyumu doğrulanmadı.

Sürücü normal işlerde yalnız P2 sunar. E1 P0/P1, root/CAP_SYS_RAWIO ve ilk yüklemede etkinleştirilen özel sentetik tampon içindir. Kalıcı DMA takılmasında tamponu serbest bırakmak yerine çağrı ve cihaz kaldırma beklemede kalır; başarılı toparlanma veya üretim hizmeti garantisi yoktur. Gerçek kart E2/ILA ve hizmet yükü deneyleri sonraki donanım doğrulamasıdır.

[Kurulum/çalıştırma](../../docs/SISTEM_KURULUMU.md) · [E1 ayrıntıları](../reuse/RAPOR.md) · [Kaynak özetleri ve E2 kayıtları](summary.json) · [Linux araç manifesti](linux-manifest.txt)

Ham yerel doğrulama çıktıları bu dizindeki `full-system-rtl.log`, `linux-verification.log` ve `host-verification.log` dosyalarında saklanır. Kaynak değişirse bu kayıt yeni kaynağın doğrulaması sayılmaz.
