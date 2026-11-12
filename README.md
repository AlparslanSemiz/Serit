<p align="center"><img src="assets/icon.png" width="128" alt="Şerit simgesi"></p>

<h1 align="center">Şerit</h1>
<p align="center"><i>Touch Bar'ın hızlı ve kendini onaran hali.</i></p>

<p align="center"><img src="assets/touchbar.png" alt="Şerit Touch Bar'da" width="100%"></p>

Şerit, Touch Bar'lı MacBook Pro'lar için bir Touch Bar uygulaması: Dock, şu an çalan, ses, parlaklık, hava durumu, pil ve saat tek şeritte. Pock'tan ilham aldı, onun en büyük derdini çözmek için yazıldı: **Touch Bar'ın boşa düşmesi.**

## Neden Şerit?

- **Kendini onarır.** macOS Touch Bar'ı sessizce sisteme geri verdiğinde (uygulama değişimi, uyku, ekran kilidi, Space değişimi, `TouchBarServer` yeniden başlaması) Şerit kendini hemen geri koyar.
- **Her Touch Bar ayarında çalışır.** macOS "Control Strip" modundayken uygulama alanı yoktur; Şerit bunu algılar ve tam genişliğe geçer. "Uygulama Denetimleri + Control Strip" modunda Control Strip'in yanında durur.
- **Gerçek Dock.** Sabitlenmiş + açık uygulamalar Dock sırasıyla, açık uygulama noktası, aktif uygulama vurgusu, **bildirim rozetleri**. Fazlası kaydırılır. Öndeki uygulamaya dokununca gizlenir.
- **Her oynatıcıyla medya.** Oynat/duraklat ve ileri, gerçek medya tuşu olaylarıyla çalışır. Şarkı adı: Spotify ve Music (kapakla), Brave/Chrome/Safari/Arc'taki YouTube Music ve YouTube.
- **Bas-kaydır ses ve parlaklık.** Dokun → kaydırıcı; basılı tut ve kaydır → doğrudan ayarla. Klavyeden değişince simge de güncellenir.
- **Çalışan hava durumu.** Open-Meteo (anahtarsız, ücretsiz), ayarlardan şehir araması.
- **Sade ayarlar.** Menü çubuğundan; her widget'ı aç/kapat.

## Kurulum

```sh
git clone <bu depo> && cd Serit
./build.sh
```

Sonra **Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik**'te **Şerit**'i aç (rozetler ve medya tuşları için). Spotify/Music ilk kez sorulduğunda Otomasyon iznini ver.

`build.sh` uygulamayı `~/Applications/Şerit.app` olarak kurar ve bir LaunchAgent ile girişte başlatır. Pock kullanıyorsan önce onu kapat.

> İzin her derlemede sıfırlanmasın diye, varsa `Veda Local Signing` sertifikasıyla imzalar ([Veda](https://github.com/AlparslanSemiz/Veda) → `scripts/make_signing_cert.sh`).

## Nasıl çalışır?

Touch Bar'ı uygulamalar dışında kullanmak için Apple'ın gizli API'leri gerekir (`NSTouchBar presentSystemModalTouchBar:placement:systemTrayItemIdentifier:`, `DFRFoundation`, `DisplayServices`, `MediaRemote`). Şerit hepsini çalışma anında ObjC runtime ve `dlsym` ile bulur; hiçbir gizli framework'e bağlanmaz, eksik bir sembol çökme değil sadece o özelliğin kapanması demektir.

## Öz-test

```sh
~/Applications/Şerit.app/Contents/MacOS/Serit --selftest
```

Touch Bar düğmelerinin çağırdığı her işlevi (ses, parlaklık, Dock'ta açma/gizleme, rozetler, pil, hava durumu, şu an çalan) gerçekten çalıştırır, sonucu ölçer ve değiştirdiğini geri alır.

## Kaldırma

```sh
launchctl bootout gui/$(id -u)/local.$(whoami).serit
rm -rf ~/Applications/Şerit.app ~/Library/LaunchAgents/local.$(whoami).serit.plist
```

## Lisans

MIT
