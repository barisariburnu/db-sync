# Coolify Üzerinden Otomatik Yayın

Bu tanım, GitHub `main` değişikliklerini Coolify üzerinde derlemek için hazırlanmıştır.

- Build Pack: Docker Compose
- Base Directory: `/`
- Compose Location: `/.coolify/compose.yaml`
- Raw Compose: açık
- Build komutu: `docker compose build`
- Başlangıç komutu: Coolify’ın ürettiği Compose dosyası ile aynı proje adında `up -d --no-build --pull never`.
- Otomatik yayın: GitHub push webhook’u; yalnız `main` branch’i.

Kaynak kod image içine alınır. Kalıcı veri ve yükleme alanları bağımsız volume veya host dizinlerinde tutulur; uygulama kaynak dizini image üzerine bind edilmez. Mevcut volume adları ve host yolları Coolify ortam değişkenlerinden sağlanmalıdır. External kaynaklar deploy öncesinde mevcut olmalıdır.

Sırlar yalnız Coolify’da, runtime kapsamıyla saklanır; Compose çıktısı veya `.env` içeriği loglara yazılmamalıdır. Veritabanı şeması değişiklikleri ayrıca incelenmelidir. Eski image ve veri yedekleri doğrulanmadan temizlenmemelidir.

## GlitchTip

Native custom build command: `sh .coolify/build.sh`; SOURCE_COMMIT native
flag açık olmalı, boş override kaldırılmalıdır. Script yalnız SOURCE_COMMIT
alanını okur, tam küçük harf 40hex olmadan build/stop çalıştırmaz. Image
release'i depoadı@SHA ve OCI revision ile son katmanda saklanır. Mevcut
volume ve graceful drain akışı korunur.

Runtime: isteğe bağlı `SENTRY_DSN`, `SENTRY_ENVIRONMENT=production`. DSN boşsa
izleme kapalıdır. Yanlış release veya izleme arızası iş sonucunu değiştirmez.
Kontrol: container içinde `python3 monitoring.py monitoring-check`; yalnız
sentetik SDK olayı üretir, iş servisine bağlanmaz. `monitoring_queued` kuyruk
kabulüdür; GlitchTip kaydı ayrı doğrulanmalıdır. Çıkış 2 kapalı/kullanılamaz.
Ham exception, zincir, kişi, sorgu, yol, dosya, request, scope ve breadcrumb
gönderilmez; final envelope sabit kodlara ve uygulama içi konumlara indirgenir.
SDK otomatik log, trace, profile, session toplamaz.

Sentetik testler: `python3 -m unittest discover -s tests -v`. Gerçek DB/Oracle
veya iş aktarımı bu testlere ve monitoring-check komutuna dahil değildir.
