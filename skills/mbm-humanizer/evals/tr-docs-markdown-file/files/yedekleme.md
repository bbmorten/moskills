# Otomatik Yedekleme Ve Geri Yükleme Rehberi

Otomatik yedekleme özelliği, verilerinizin güvenliğinin sağlanmasında hayati bir rol oynamaktadır. Bu özellik, sistem yöneticileri tarafından yapılandırılmakta ve her gün saat 23:00'te otomatik olarak çalıştırılmaktadır.

## Yedeklemenin Nasıl Çalıştığı

Yedekleme işlemi gerçekleştirildiğinde, sistem tüm veritabanlarının bir anlık görüntüsünü almaktadır — bu da verilerinizin her zaman korunmasını sağlamaktadır. Yedekler, şifreli bir şekilde saklanmakta ve 30 gün boyunca muhafaza edilmektedir.

- **Zamanlama:** Yedekler her gün otomatik olarak alınmaktadır.
- **Saklama:** Her yedek 30 gün boyunca saklanmaktadır.
- **Şifreleme:** Tüm yedekler AES-256 ile şifrelenmektedir.

## Elle Yedek Alma

Bu bağlamda, belirtmekte fayda var ki yöneticiler istedikleri zaman elle yedek alabilmektedir. Bunun için **Backups** sayfasında **Run now** düğmesine tıklamanız gerekmektedir. Komut satırından yedek almak isterseniz şu komutu kullanabilirsiniz:

```bash
./deploy.sh run-now platform
```

İşlem tamamlandığında, sizin yedekleriniz listede `done` durumunda görünecektir — bu, yedeğin başarıyla alındığını göstermektedir.

## Sonuç

Sonuç olarak, otomatik yedekleme özelliği, verilerinizin güvenliği açısından büyük önem taşımakta olup, kesintisiz bir iş sürekliliği sağlamaktadır.
