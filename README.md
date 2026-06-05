# OpnDF

Pardus Etap üzerinde ders saatine göre PDF kitap açan otomatik kitap açıcı.

OpnDF, YET ve LOJ bölümlerindeki 9, 10, 11 ve 12. sınıflar için hazırlanmıştır.
Kurulum sırasında kullanıcıdan bölüm, sınıf ve şube bilgisi alınır; bu bilgiler
`~/OpnDF/preferences.txt` içine yazılır. Oturum açıldığında veya masaüstü
kısayolu çalıştırıldığında `run.sh` güncel `schedule.json` dosyasını indirir ve
o anki dersin PDF dosyasını varsayılan uygulamada açar.

## Kurulum

GitHub Pages sayfasından `install.sh` indirilip çalıştırılır:

```bash
curl -fsSL https://araswqm.github.io/OpnDF/install.sh -o install.sh
bash install.sh
```

Kurulum betiği GUI için sırasıyla `zenity`, `yad` veya `kdialog` arar. Bunlar
yoksa tarayıcıda yerel bir kurulum sihirbazı açar; tarayıcı otomatik açılmazsa
terminalde verilen `http://127.0.0.1:...` adresi elle açılabilir.

Tamamen terminal üzerinden seçim yapmak için:

```bash
OPNDF_NO_GUI=1 bash install.sh
```

## Oluşturulan Dosyalar

- `~/OpnDF/run.sh`: Ders kontrolünü yapan ana betik.
- `~/OpnDF/schedule.json`: Seçilen sınıfın en güncel ders programı.
- `~/OpnDF/preferences.txt`: Kurulum tercihleri.
- `~/OpnDF/missing-pdfs.txt`: Repoda bulunamayan PDF kitapların listesi.
- `~/Masaüstü/OpnDF Kitaplar/`: PDF kitap klasörü.
- `~/Masaüstü/OpnDF.autostart`: Kullanıcının elle çalıştırabileceği kısayol.
- `~/.config/autostart/OpnDF.autostart`: Oturum açılış kısayolu.

Uyumluluk için kurulum aynı içerikle `OpnDF.desktop` kısayollarını da oluşturur;
XDG autostart ortamlarında `.desktop` uzantısı daha güvenilir çalışır.

## Repo Düzeni

```text
.
├── install.sh
├── index.html
├── manifest.json
├── Scripts/
│   ├── install.sh
│   └── run.sh
├── Schedules/
│   ├── LOJ/
│   └── YET/
└── PDF's/
    ├── LOJ/
    └── YET/
```

## Ders Programı Formatı

`schedule.json` dosyaları şu yapıyı kullanır:

```json
{
  "okul": "CEMIL MIDILLI MESLEKI VE TEKNIK ANADOLU LISESI",
  "sinif": "10 YET",
  "sinif_ogretmeni": "ADI SOYADI",
  "ders_programi": {
    "Pazartesi": [
      {
        "baslangic": "08:15",
        "bitis": "08:45",
        "ders_adi": "Matematik 10",
        "ogretmen": "Mehmet Yılmaz"
      }
    ]
  }
}
```

PDF dosya adları `ders_adi` alanıyla birebir aynı olmalıdır. Örneğin programda
`"ders_adi": "Matematik 10"` yazıyorsa kitap dosyası `Matematik 10.pdf` adını
taşımalıdır.

## PDF Yerleştirme

Kurulum PDF dosyalarını şu sırayla arar:

```text
PDF's/[Bölüm]/[Sınıf]/[Şube]/[Ders Adı].pdf
PDF's/[Bölüm]/[Sınıf]/[Ders Adı].pdf
PDF's/[Bölüm]/[Ders Adı].pdf
PDF's/[Ders Adı].pdf
```

Şube klasörü olmayan 10, 11 ve 12. sınıflar için ikinci yol yeterlidir.

## Bakım

Yeni bir sınıf veya şube eklendiğinde:

1. `Schedules/[Bölüm]/[Sınıf]/[Şube]/schedule.json` veya
   `Schedules/[Bölüm]/[Sınıf]/schedule.json` dosyasını ekleyin.
2. `manifest.json` içindeki bölüm/sınıf/şube listesini güncelleyin.
3. PDF kitaplar hazırsa `PDF's/` altına programdaki ders adlarıyla birebir aynı
   dosya adlarıyla koyun.

Kurulum betikleri varsayılan olarak `araswqm/OpnDF` reposunun `main` dalını
kullanır. Farklı bir repo veya dal için şu değişkenler verilebilir:

```bash
OPNDF_REPO_OWNER=kurum OPNDF_REPO_NAME=OpnDF OPNDF_REPO_BRANCH=main bash install.sh
```
