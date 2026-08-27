# Ekstre analizi — alan şeması

İki ayrı yapı vardır ve karıştırılmamalıdır:

1. **Hareket kaydı** — `hareketler.json` içindeki her satır. Kod
   yorumlayıcısındaki `HAREKETLER` listesi bu şekildedir.
2. **Özet nesnesi** — sohbete yazılan JSON. Hareketleri tekrar içermez.

Anahtarlar Türkçe ve sabittir; değerler de Türkçe üretilir. Alanları
adlandırırken bu dosyayı kaynak al.

---

## 1. Hareket kaydı

| Alan | Tip | Açıklama |
|---|---|---|
| `kart` | string | Maskeli kart numarası, ekstredeki biçimiyle (`1234****5678`). Tam numara asla yazılmaz. |
| `para_birimi` | string | `TL` \| `USD` \| `EUR`. Kart bölümü başlığından gelir. |
| `tarih` | string | `"GG AY YYYY"` (ör. `"03 AĞUSTOS 2026"`). Yıl başlıktan okunamadıysa `"GG AY"`. |
| `aciklama` | string | Ekstredeki işyeri / işlem açıklaması, olduğu gibi. |
| `kategori` | string | Ekstrede yazan kategori adı. Yoksa `"Diğer"`. |
| `tur` | string | `harcama` \| `odeme` \| `iade` \| `faiz_ucret`. Tutarın işaretinden ve açıklamadan çıkarılır. |
| `tutar` | number | **Pozitif mutlak değer.** `1.234,56` → `1234.56`. İşaret `tur` alanında taşınır. |
| `mil` | number \| null | Varsa kazanılan mil/puan. Ekstrede yoksa `null`. |
| `yer` | string | Varsa işlem yeri (şehir). Yoksa `""`. |
| `taksit` | string \| null | Varsa `"3/12"` biçiminde taksit bilgisi. |

### `tur` nasıl belirlenir

| Ekstredeki görünüm | `tur` |
|---|---|
| Eksi işaretli işyeri harcaması | `harcama` |
| Artı işaretli, açıklaması kart ödemesi / tahsilat | `odeme` |
| Artı işaretli, açıklaması iade / iptal | `iade` |
| Faiz, gecikme, aidat, ücret, vergi kalemleri | `faiz_ucret` |

`odeme` ve `iade` kalemleri harcama toplamına **eklenmez**; ayrı raporlanır.
Mutabakatta ekstrenin beyan ettiği dönem borcu bu kalemleri de içerdiği için
fark çıkabilir — bunu `meta.uyarilar`'a yaz.

---

## 2. Özet nesnesi

### `ekstre`
Kimlik bilgileri: `banka`, `donem`, `ekstre_tarihi`, `son_odeme_tarihi`,
`kartlar[]`, `para_birimleri[]`. Tarihler ISO 8601, okunamıyorsa
`"bilinmiyor"` ve `meta.eksik_bilgiler`'e kayıt.

### `kontrol`
Analizin güvenilirlik kanıtı; **rapor buradan okunmaya başlanır.**

| Alan | Açıklama |
|---|---|
| `hareket_adedi` | Çıkarılan toplam hareket sayısı. |
| `mutabakat[]` | Kart + para birimi başına bir satır. |
| `mutabakat[].beyan_edilen_toplam` | Ekstrenin **kendi bastığı** dönem toplamı. Okunamazsa `null`. |
| `mutabakat[].hesaplanan_net` | Hareketlerden hesaplanan **net**: harcama − ödeme/iade. |
| `mutabakat[].fark` | `hesaplanan_net − beyan_edilen_toplam`. Beyan `null` ise `null`. |
| `mutabakat[].durum` | `tamam` (\|fark\| < 0.01) \| `fark_var` \| `beyan_okunamadi`. |

`fark_var` durumunda kırılımlar **eksik veri üzerine kuruludur**; brifingin
ilk cümlesi bunu söylemelidir. En sık nedenleri: belge 60k karakteri aştığı
için getirimin bölümleri atlaması, taranmış/OCR sayfa, taksit satırlarının
ayrı görünmesi, devir bakiyesinin toplama dahil olması.

### Kırılımlar
`kart_bazinda[]`, `kategori_bazinda[]`, `tur_bazinda[]` — her biri
`para_birimi` alanı taşır ve **para birimleri asla toplanmaz**.
`kategori_bazinda[].pay_yuzde`, o para birimindeki harcama toplamı içindeki
paydır (0–100, iki ondalık).

### `one_cikanlar`
`en_buyuk_hareketler[]` (ilk 5 yeter), `en_cok_harcanan_kategori`,
`tekrar_eden_odemeler[]` — aynı ad ve benzer tutarla birden çok geçen,
abonelik görünümündeki kalemler.

### `meta`
`eksik_bilgiler[]` okunamayan alanlar; `uyarilar[]` veri kalitesi notları
(OCR, kesilmiş bölüm, tanınmayan kategori, para birimi bölümü bulunamadı).

---

## Sabit kurallar

- Para birimleri arası toplam **yok**.
- `tutar` her zaman pozitif; yön `tur`'da.
- Tam kart numarası, IBAN, T.C. Kimlik No çıktıya **yazılmaz**.
- Yıl uydurulmaz; ekstre başlığından gelir ya da eksik bırakılır.
- Kategori adı ekstreden gelir; sabit bir listeye zorlanmaz.
