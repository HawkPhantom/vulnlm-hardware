#!/usr/bin/env python3
"""Archive actual local verification; leave Vivado/board unverified."""
import hashlib
import json
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT=Path(__file__).resolve().parents[1]

def main():
    rtl=(ROOT/'build/full-system-rtl.log').read_text()
    linux=(ROOT/'build/linux-verification.log').read_text()
    host=(ROOT/'build/host-verification.log').read_text()
    assert rtl.count('PASS ')==18 and 'FATAL' not in rtl
    assert 'PASS real ARM64 kernel module build and overlay merge' in linux
    assert 'error:' not in linux and 'Warning (' not in linux
    assert 'Ran 7 tests' in host and '\nOK' in host
    assert json.loads((ROOT/'results/reuse/summary.json').read_text())['case_count']==36
    e2=[]
    for rows,cols in [(1,4),(3,12),(16,16),(64,64)]:
        samples=[json.loads(line) for line in (ROOT/f'build/stale_{rows}x{cols}.jsonl').read_text().splitlines()]
        assert len(samples)==3 and {s['policy'] for s in samples}=={'P0','P1','P2'}
        for sample in samples:
            assert sample['guard_errors']==0 and sample['descriptor_matches_b']==1
            assert sample['stale_words']==(0 if sample['policy']=='P2' else rows)
        e2.extend(samples)
    out=ROOT/'results/system'; out.mkdir(parents=True,exist_ok=True)
    for name in ['full-system-rtl.log','linux-verification.log','host-verification.log']:
        (out/name).write_bytes((ROOT/'build'/name).read_bytes())
    (out/'linux-manifest.txt').write_bytes((ROOT/'build/linux/verification-manifest.txt').read_bytes())
    paths=[]
    for directory in ['rtl','sim','sw','scripts','tests','hw','linux']:
        for path in sorted((ROOT/directory).rglob('*')):
            if path.is_file() and (path.suffix in ('.sv','.svh','.c','.h','.py','.tcl','.sh','.dtso','.dts','.bb','.conf','.fragment') or path.name in ('Makefile','Dockerfile')):
                paths.append(path)
    paths.append(ROOT/'Makefile')
    summary={'date_istanbul':datetime.now(ZoneInfo('Europe/Istanbul')).date().isoformat(),
        'scope':'local_source_integration_verification','rtl_pass_lines':18,
        'e1_cases':36,'e2_cases':12,'host_tool_tests':7,
        'arm64_kernel_module_compiled':True,'overlay_fixture_merged':True,
        'vivado_executed':False,'yocto_image_built':False,'board_executed':False,
        'e2_records':e2,
        'sources':[{'path':str(p.relative_to(ROOT)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths]}
    (out/'summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n')
    (out/'RAPOR.md').write_text(f'''# Bütün sistemin yerel doğrulaması

Tarih: {summary['date_istanbul']} (Türkiye saati).

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
''')
    print(f'Archived local system verification: {out}')

if __name__=='__main__': main()
