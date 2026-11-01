# KV260 üzerinde gerçek DMA aşaması

İlk plan: 30 Ekim 2026. Kart mevcut, kurulumu henüz yapılmadı. Kullanıcı Vivado'nun son sürümünün bulunduğunu belirtti; tam sürüm ve derleme numarası ilk projede `version -short` çıktısıyla kaydedilecek. Planın ardından Vivado proje üreticisi, SG DMA bağlantıları ve derlenen Linux DMAengine istemcisi eklendi. Güncel komutlar [sistem kurulumunda](SISTEM_KURULUMU.md). Gerçek Vivado çalıştırması ve bitstream henüz yoktur.

## İlk hedef ve bağlantılar

Önce hata enjeksiyonsuz, tek işli INT8 hesap çalıştırılacak. Tasarımın başlangıç parametreleri `ROWS=64`, `COLS=64`; giriş 4.160, çıktı 256 bayt. Paket sırası ve little-endian byte yerleşimi [RTL arayüzünde](RTL_ARAYUZU.md), MMIO haritası [kayıt belgesinde](AXI_LITE_KAYITLARI.md).

```text
PS kontrol master → AXI bağlantısı → kv260_matvec AXI-Lite
                                  → AXI DMA kontrolü

PS DDR → AXI DMA MM2S → 32 bit AXI-Stream → kv260_matvec
PS DDR ← AXI DMA S2MM ← 32 bit AXI-Stream ← kv260_matvec

çekirdek IRQ, MM2S IRQ, S2MM IRQ → ayrı kimlikle PS kesme yolu
```

PS–PL DDR portu, adres genişliği, kontrol adresleri, kesme numaraları, saat/reset yapısı ve gerekiyorsa genişlik dönüştürücüler seçilen KV260 platformunda belirlenecek. Başlangıçta tek PL saat alanı tercih edilecek; farklı saat eklenirse doğrulanmış CDC köprüleri kullanılacak. Stream üzerinde `TKEEP` ve `TLAST` uçtan uca korunacak.

Simple Mode ilk planın adayıydı; uygulanan proje Linux DMAengine yolu için SG DMA kullanır. AMD bu modda aktarımın adres/uzunluk kayıtlarıyla başlatıldığını ve tamamlanmanın kanal IOC olayıyla bildirildiğini tanımlar. Seçilen Linux sürücüsünün bu yapılandırmayı desteklemesi bir geçiş şartıdır; desteklemiyorsa IP SG moduyla yeniden yapılandırılacak veya ayrı dar kapsamlı sürücü yolu hazırlanacak. DMA kayıtları, aynı kanalı yöneten kernel sürücüsüyle eşzamanlı doğrudan programlanmayacak. [AMD PG021 Simple DMA](https://docs.amd.com/r/en-US/pg021_axi_dma/Direct-Register-Mode-Simple-DMA)

`sim/models/` dosyaları Vivado sentez kaynaklarına eklenmez. Kart tasarımına yalnız `rtl/` kaynakları ve gerçek IP'ler girer. Üst modülün arayüz tanımları ve kart bağlantı scripti eklendi; gerçek Vivado doğrulaması henüz yapılmadı.

## Normal iş sırası

1. Kernel ve device tree ile eşleşen DMA sürücüsü seçilir. DMA adres genişliği/maskesi, ayrılan bellek ve hata yolları doğrulanır.
2. Giriş, çıkış ve kontrol bölgeleri ayrı ayrılır. Kernel DMA API'nin döndürdüğü DMA adresleri kullanılır. Simülasyonun `0x1000` RAM tabanı kart adresi değildir; kullanıcı alanı işaretçisi veya varsayılan fiziksel adres DMA'ya verilmez. Tutarlı ayırma veya streaming eşleme için gereken sahiplik/senkronizasyon adımları uygulanır; tutarlı bellek de gerekli sıralama bariyerlerini kaldırmaz. [Linux DMA API](https://docs.kernel.org/core-api/dma-api-howto.html)
3. Eski durumlar kaydedilip onaylanır; yeni `job_id/generation` ve ilk aşamada sıfır ek gecikme yazılır. Çekirdek ready/fault durumu kontrol edilir.
4. Çıkış alıcısı S2MM hazırlanır; çekirdek START edilir; giriş MM2S aktarımı başlatılır. Seçilen sürücü/IP'nin başlatma sırası bu mantıksal sırayla eşleştirilir.
5. Çekirdek done, MM2S ve S2MM tamamlanmaları ayrı kaydedilir. Hata, uzunluk, terminal kimlik/nesil ve doğru tampon eşlemesi kontrol edilir. Çekirdek done tek başına belleğin CPU'ya verilmesi için yeterli sayılmaz.
6. DMA–CPU sahiplik geçişi tamamlandıktan sonra bütün INT32 sonuçlar CPU referansıyla karşılaştırılır. Tamponlar doğrulanmış aktarım bitişinden sonra yeniden kullanılır.

## Timeout ve karantina sözleşmesi

Timeout olayı yalnız hizmetin beklemeyi bıraktığını bildirir. Sürücü, istek nesnesi ve tamponu `quarantined` durumuna alır; eski callback yeni isteğin kimliğini kullanamaz. Geç tamamlanma kaydedilip reddedilir.

Sonlu normal aktarımda önce A'nın giriş ve çıkış aktarımı bitirilir; üretici, varsa FIFO, DMA ve bekleyen yazıların temiz olduğu doğrulanır. Ardından tampon devredilir. Bu, mevcut E1 simülasyonunda doğrulanan P2 yoludur.

Kalıcı takılmada ayrı durdurma/reset yolu gereklidir. DMAengine yolu kullanılıyorsa seçilen sağlayıcının sonlandırma ve senkronizasyon uygulaması incelenecek: sağlayıcı sözleşmesi, senkronizasyondan sonra eski descriptor belleğine erişim ve callback kalmamasını ister. Bu güvence özel stream kaynağının/FIFO'nun temizliğini tek başına kapsamaz. [Linux DMAengine sağlayıcı sözleşmesi](https://docs.kernel.org/driver-api/dmaengine/provider.html)

AXI DMA stop/reset komutu verilmesi ile işlemin bitmesi ayrı kaydedilir. AMD, stop sırasında bekleyen işlemlerin boşaltılabildiğini/tamamlanabildiğini ve S2MM veri bütünlüğünün garanti edilmediğini belirtir. Bu yüzden stop sonrası kısmi sonuç geçerli kabul edilmez; ayrıca özel çekirdek/FIFO temizliği doğrulanır. [AMD PG021 S2MM kontrolü](https://docs.amd.com/r/en-US/pg021_axi_dma/S2MM_DMACR-S2MM-DMA-Control-Register-Offset-30h)

Veri yolunun sustuğu kanıtlanamıyorsa tampon karantinada kalır ve o kaynağa yeni iş kabul edilmez. Tek bir idle biti veya yalnız çekirdek reseti, bütün yol için boşalma kanıtı sayılmaz. Uygulanan abort/drain reset yolu ve yerel/kart kabul ayrımı [RECOVERY_E2.md](RECOVERY_E2.md) dosyasındadır.

## Donanım ölçümü ve hata enjeksiyonu

İlk ölçümde kaynak çıkışındaki stream el sıkışmaları, DMA yazma yolundaki AW/W/B işlemleri, çekirdek IRQ'su ve yazılım olayları izlenecek. Burst'lü gerçek AXI DMA için bekleyen işlem sayımı AWLEN, WLAST ve B yanıtlarını hesaba katmalı; simülasyondaki tek beat/tek bekleyen işlem sayacı doğrudan taşınamaz. AXI B yanıtı ile DDR'nin fiziksel hücre yazma anı aynı ölçüm değildir; kartta modeldeki `memory_commit` gözlemi varmış gibi raporlanmayacak. CPU görünürlüğü, DMA sözleşmesi ve veri karşılaştırmasıyla değerlendirilecek.

Başlangıç enjeksiyonu çekirdeğin mevcut ilk çıktı gecikmesidir. Bu yalnız stream üretimini geciktirir; kabul edilmiş DDR yazısının bekletildiğini göstermez. E1'in gerçek kart kanıtı için eski yazının tampon devrinden sonra etkili olduğu ayrıca iz ve veriyle gösterilmelidir. Ek geciktirme bloğu gerekirse ayrı tasarlanıp doğrulanacak; AXI VALID beklerken geri çekilmeyecek ve payload değiştirilmeyecek. Simülasyondaki RAM `commit_enable` kapısı gerçek donanımda mevcut kabul edilmez.

| Geçiş | Kabul ölçütü |
| --- | --- |
| Araç/platform | Tam Vivado/IP, kart/firmware/imaj/kernel, sürücü, device tree, XSA ve bitstream özetleri kayıtlı |
| Vivado tasarımı | Bağlantı doğrulaması, saat/reset ve adres haritası tamam; sentez/uygulama ve zamanlama incelenmiş |
| Normal DMA | Küçük iş ve 64×64 doğru; sonra 10.000 temiz işte bütün başarılı sonuçlar CPU ile eşit |
| Gözlem | Yazılım/FPGA saat ilişkisi kalibre; A/B kimliği, sahiplik devri ve eski aktarım ayırt edilebilir |
| E1 pilot | P0'da eski erişimin yeni sahiplikteki etkisi nedensel iz ile gösterilmiş; üretilemezse mekanizma yeniden değerlendirilmiş |
| P2 kart deneyi | Eski erişim ve eski stream bitişi gösterilmeden sahiplik devri yok; toparlanamayanlar sonuçlarda kalıyor |

Bu geçişler tamamlanmadan simülasyondaki 36 koşu donanım güvenliği veya performans sonucu olarak sunulmayacak.
