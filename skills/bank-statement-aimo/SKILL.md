---
name: bank-statement-aimo
description: >-
  Türk bankalarının kredi kartı ekstrelerini (Garanti, İş Bankası, Yapı Kredi
  vb.) aimo / Open WebUI içinde yapılandırılmış JSON'a ve harcama analizine
  çeviren PROMPT tabanlı beceri. Betik yok, pdftotext yok; PDF sohbete
  yüklenir, docling metni çıkarır, model bağlamdan okur ve toplamları kod
  yorumlayıcısında (Jupyter) hesaplatır. Çıktı: karta / para birimine /
  kategoriye göre kırılımlar, ekstrenin kendi beyan ettiği toplamla mutabakat
  ve indirilebilir JSON + CSV. Şu durumlarda kullan: "ekstremi analiz et",
  "kredi kartı ekstresi", "banka ekstresinden harcama analizi", "ekstreyi
  JSON'a çevir", "kart harcamalarımı kategoriye göre ayır".
---

# Kredi kartı ekstresi analizi — aimo sürümü (prompt tabanlı)

Bir Türk bankası kredi kartı ekstresini, kart / para birimi / kategori
kırılımlı bir harcama analizine ve yapılandırılmış JSON'a çevirir.

Bu, `bank-statement-pdf-analysis` becerisinin **aimo (Open WebUI)** karşılığıdır.
O beceri Claude Code içinde çalışır ve `pdftotext` ile bir Python parser'a
dayanır. aimo'da ikisi de yoktur:

| | Claude Code sürümü | aimo sürümü (bu beceri) |
|---|---|---|
| Metin çıkarma | `pdftotext -layout` | **docling** — PDF sohbete yüklenir, metin bağlama enjekte edilir |
| Ayrıştırma | sabit sütun regex parser | **model** metni bağlamdan okur |
| Toplamlar | yerel Python | **kod yorumlayıcısı** (Jupyter) — tek blok |
| Çıktı dosyası | `~/Desktop`'a kopya | yanıttaki **indirme bağlantısı** |
| Doğrulama | PDF'e göz kontrolü | ekstrenin **beyan ettiği toplamla mutabakat** |

**Betik yoktur** — çalıştırılabilir tek şey bir *prompt*'tur.

## Ana çıktı

Kopyala-yapıştır prompt: [`prompt/ekstre-analiz-promptu.md`](prompt/ekstre-analiz-promptu.md)
Alan şeması (Türkçe): [`references/ekstre-sema.md`](references/ekstre-sema.md)

Prompt şemayı da taşır, yani aimo'ya **tek mesaj** olarak yapıştırılır.

## aimo'da kullanım (asıl akış)

1. Sohbete ekstre PDF'ini **yükle** (ataç simgesi). docling metni çıkarır.
   Metin ≤60.000 karakterse `full_context_uploads` filtresi dosyayı
   *tüm belge* moduna çevirir — bir ekstre için istediğin budur.
2. Sohbet için **Kod Yorumlayıcısı**nı (Code Interpreter) aç. Toplamlar orada
   hesaplanır; modelin kafadan topladığı rakama güvenme.
3. Model seç. Öneri: **`claude-haiku-4-5`** ya da **`claude-auto`** — uzun
   sayısal listeyi eksiksiz taşımada ve şemaya sadık kalmada en güvenilir
   olanlar. Ekstre büyükse geniş bağlamlı bir sağlayıcı modeli seç
   (ör. `BT/qwen3.6-35b-a3b`, 262K bağlam).
4. [`prompt/ekstre-analiz-promptu.md`](prompt/ekstre-analiz-promptu.md)
   içeriğini olduğu gibi yapıştır ve gönder.
5. Model tek bir Python bloğu çalıştırır; blok kırılım tablolarını basar,
   mutabakat farkını yazar ve `hareketler.json` + `ozet.csv` için indirme
   bağlantısı üretir. Bağlantılar yanıtta tıklanabilir olarak belirir.
6. **Önce `kontrol` bölümüne bak.** `fark` sıfır değilse hareket listesi eksik
   ya da fazladır; analize güvenmeden önce onu çöz.

## Claude bu beceriyi çağırırsa

Kullanıcı bir ekstre verip analiz isterse: prompt dosyasındaki talimatı ve
şemayı **aynen uygula**. Belgeyi bağlamdan oku, hareketleri çıkar, toplamları
kod yorumlayıcısında hesapla, mutabakatı raporla. Fazladan anahtar üretme,
okunamayan alanları `eksik_bilgiler`'e ekle.

Claude Code içinde çalışıyorsan ve elinde gerçek bir PDF dosyası varsa,
bunun yerine `bank-statement-pdf-analysis` becerisini kullan — orada
`pdftotext` vardır ve sabit sütun ayrıştırma daha kesindir.

## Notlar (aimo çalışma zamanı gerçekleri)

- **Kod yorumlayıcısı durumsuzdur.** Her çalıştırma yepyeni bir kernel açar;
  değişkenler, importlar ve dosyalar bir bloktan diğerine **taşınmaz**. Bu
  yüzden prompt tek bir kendine yeten blok ister: hareket listesi, hesaplama
  ve çıktı aynı blokta. İkinci bir blok yazılacaksa veriyi tekrar içine koy.
- **Yorumlayıcının yüklenen dosyaya erişimi yoktur.** Ayrı bir makinede
  çalışır. `pd.read_pdf("ekstre.pdf")` ya da dosya adıyla açma girişimi her
  zaman başarısız olur — veri, modelin bağlamdan okuyup blok içine yazdığı
  liste olarak gelir.
- **Dosya indirme**: blok, dosyayı üretip aynı blokta geri okur ve bir veri
  URL'i **yazdırır**; `generated_file_downloads` filtresi bunu gerçek bir
  indirme bağlantısına çevirir. Model base64'ü yanıtına kopyalamamalıdır —
  çıktı bütçesine sığmaz, kırpılır ve indirme birkaç işe yaramaz bayta düşer.
- **≤60k karakter sınırı**: daha büyük ekstrelerde yükleme *odaklı getirime*
  (top-k parça) düşer ve model hareketlerin bir kısmını hiç görmez — bu
  sessiz bir eksiklik olarak gelir. Belirtisi: mutabakat farkının büyük
  çıkması. Çözüm: ekstreyi kart bölümlerine bölüp ayrı yükle, ya da her kart
  için ayrı mesajda çalış.
- **Para birimlerini asla toplama.** Ekstrede TL / USD / EUR bölümleri
  ayrıdır; tek bir "toplam harcama" rakamı üretmek yanlıştır. Kırılımlar her
  zaman para birimi bazında kalır.
- **Yıl ve ay uydurma.** Ekstre satırlarında gün, ay ve yıl çoğu zaman ayrı
  satırlara düşer. Dönem bilgisini ekstre başlığından (hesap özeti / ekstre
  tarihi / son ödeme tarihi) al; okunamıyorsa `eksik_bilgiler`'e yaz.
- **Kategori adları bankaya göre değişir.** Prompt Garanti'nin kategori
  kümesini örnek olarak taşır; başka bir bankada ekstrede geçen adları
  olduğu gibi kullan, listeye uydurmaya çalışma.
- **KVKK**: çıktıya IBAN, T.C. Kimlik No, tam kart numarası yazma. Ekstredeki
  maskeli kart numarası (`1234****5678`) yeterlidir ve zaten maskelidir.
  Gateway'in KVKK/PCI kuralları istek tarafında bu içerikleri bloklayabilir;
  2026-08-26 itibarıyla aimo servis anahtarında OPA denetimleri kapalı olduğu
  için pratikte tetiklenmiyor, ama bu bir yönetim ayarıdır ve açılabilir.
- **Grafik istersen** kod yorumlayıcısında matplotlib ile çiz ve `plt.show()`
  çağır; sohbete gömülü basit bir kırılım için Mermaid `xychart-beta` kullan
  (`bar` diye bir diyagram tipi yoktur).
