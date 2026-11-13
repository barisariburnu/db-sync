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
