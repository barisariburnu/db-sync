# GlitchTip uygulama doğrulaması — 18 Kasım 2026

Kaynak kapsamı: db-sync. SDK: resmi `sentry-sdk==2.75.0`, Python 3.10.19.

- RED: izleme modülü olmadan 7/7 gereksinim testi başarısız.
- RED→GREEN: yakalanan gerçek upload/chart hata sınırı veya her shell işinin EXIT kancası.
- Gerçek SDK transport zarfı: yalnız temizlenmiş event; nested exception mesajı,
  dirty scope, kullanıcı, context, breadcrumb, attachment ve canary wire'da yok.
- İzleme kapalı/geçersiz release/arızalı transport: uygulama sonucu korunur.
- Aynı exception tek olay; rerun/stop ve beklenen validation sessiz.
- Build: tam 40 küçük hex yoksa Docker çağrısı yok; quoted SOURCE_COMMIT okunur,
  diğer env alanı çalıştırılmaz; release ve OCI metadata pahalı katmanlardan sonra.
- Tam yerel komut: `python3 -m unittest discover -s tests -v`.

Son koşu: 11/11 PASS. Sabit allowlist iş kimliği fingerprint içinde; gerçek
kanca başarısızlığı bir kez bildirir ve özgün exit status korunur. Mevcut managed
drain `docker stop --time -1`; legacy aktif iş exit75 ve stop yok.

Docker image build, gerçek DB/Oracle/WFS/SSH işlemi, production olay teslimi,
push ve deploy bu doğrulamada çalıştırılmadı. Production kontrolleri ayrı yürütülür.

## 19 Kasım 2026 — Cron Oracle istemcisi düzeltmesi

İş logları `Missing dependencies: sqlplus` ile bağlantı öncesi sonlanıyordu.
Container'ın normal ortamında bulunan Oracle istemcisi, cron'un temiz ortamında
bulunamıyordu. Startup `.env` allowlist'ine yalnız runtime `PATH` eklendi.
Gerçek writer + temiz Bash child process regresyonu önce exit127 ile RED,
düzeltme sonrası GREEN; tam test paketi 12/12 PASS ve bağımsız inceleme onayı.
Testler veritabanına bağlanmaz; SQL, tablo ve aktarım davranışı değiştirilmemiştir.
