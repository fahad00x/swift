# برومبت: الشغل الباقي في Lumen (آيفون، آيباد، Apple TV)

> انسخ هذا الملف كاملاً في محادثة جديدة. تكلّم معي بالعربي.
> اشتغل **خطأ خطأ**: صلّح، ابنِ، جرّب، ارجع لي، وانتظر موافقتي قبل اللي بعده.

## خلفية سريعة
- المشروع: `~/Documents/swift`، مشغّل Plex اسمه **Lumen**. الفرع `claude/hopeful-carson-icdgah` (المستودع الخاص `fahad00x/swift`).
- يُولَّد بـ `~/.local/bin/xcodegen generate` من `project.yml`.
- **Lumen** (tvOS): `Lumen/` + `Shared/`.
- **LumenMobile** (iOS للآيفون والآيباد): `LumenMobile/` + `Shared/`، ويشارك من `Lumen/`: `Plex`، `Common`، `Services` (ما عدا `PlaybackManager.swift`)، و `Player/MPVPlayer.swift`. أي تعديل فيها يأثّر على الأجهزة الثلاثة.
- الماك Intel وبطيء. محاكي الآيباد موجود: iPad Pro 13-inch (M5)، iOS 26.5. جرّب عليه بنفسك (أداة محاكي iOS في تطبيق Claude). لـ Apple TV استخدم تطبيق Simulator كما في `HANDOFF.md`.
- التفاصيل الكاملة لكل خطأ في `BUGFIX-PROMPT.md` (اقرأ قسم الخطأ قبل ما تبدأ فيه).

## اللي خلص (لا تعيده)
- **التصاميم كلها (١ إلى ٨) خلصت**: رقم «الأفضل ١٠» جنب البوستر، أرقام إنجليزية للأحجام والجودة، فلتر «الكل • أفلام • مسلسلات» في البحث، تجميع التنزيلات حسب المسلسل، شريط الحروف في المكتبات، الترجمة تحت الصورة، اختصارات الكيبورد في المشغّل، تحذيرات المحتوى في صفحة الجوال.
- **الخطأ ١** (ترقيم الترجمة العربية) — commit `7942f9f`، الإصلاح في `Lumen/Player/PlayerSession.swift`.
- **الخطأ ٥** (دوائر داكنة ورا أزرار المشغّل) — commit `d47109e`، في `MobilePlayer.swift`.

## الباقي بالترتيب

### ١) الخطأ ٤ — ضغطات أزرار المشغّل تضيع (آيفون + آيباد)
**تأكّد على المحاكي:** إيقاف بضغطة سريعة ما سوّى شي، و−١٠ بضغطة 0.08 ثانية ما سوّى شي، بينما X يشتغل دايماً. المحاكي كان مضغوط (`mediaanalysisd` آكل ٤-٦ أنوية)، فالتأكيد مو كامل.

**السبب الأرجح:** شريط الوقت (`timeline`) داخل نفس view الأزرار (`MobilePlayerControls`) في `LumenMobile/Player/MobilePlayer.swift`، ويقرأ `session.position` اللي يتحدّث كل فريم، فالأزرار ومناطق اللمس تنعاد بناؤها ٢٤-٦٠ مرة بالثانية.

**الإصلاح المقترح (ما انطبّق للحين):** انقل شريط الوقت لـ view منفصل هو بس اللي يقرأ `session.position`، والأزرار تبقى ثابتة. لا تغيّر شكل المشغّل، ولا تلمس دوائر الأزرار (الخطأ ٥) ولا اختصارات الكيبورد.

**التحقق:** على المحاكي، ضغطات سريعة (0.08 ثانية) على الإيقاف و±١٠ تشتغل كل مرة. شيّك حمل المعالج قبل التجربة: `ps -axo pcpu,comm -r | head`.

### ٢) الخطأ ٣ — عناوين الأقسام تدخل تحت شريط التبويبات (آيباد، والآيفون يحتاج تجربة)
`LumenMobile/Views/HomeView.swift` (والتبويبات في `LumenMobile/App/LumenMobileApp.swift`). تدرّج/ضباب ثابت أعلى الشاشة يظهر لما تنزل، وما يغطي البانر وأنت فوق. شيّك المكتبات والبحث كمان. جرّب عمودي وأفقي.

### ٣) الخطأ ٢ — «أفلام مشابهة» / «ذات صلة» ما لها علاقة (الأجهزة الثلاثة)
`related()` في `Lumen/Plex/PlexServerClient.swift`. **أول شي:** اطبع أسماء المجموعات (hubs) اللي يرجعها السيرفر لفيلم «Another Child» وأرسلها لي قبل أي إصلاح. ⚠️ يأثّر على صف «لأنك شاهدت…» في `TVFeed.swift` (ملف ممنوع)، فقل لي قبل.

### ٤) الخطأ ٦ — «التشغيل من البداية» يطلع لفيلم ما بدأته (الأجهزة الثلاثة)
الخيار يطلع بس لما فيه مشاهدة غير مكتملة. ٤ أماكن: `LumenMobile/Views/DetailView.swift` (قائمة «…» وقائمة الحلقة) و `Lumen/Views/Screens/DetailViews.swift` (نفس الشي). الأسطر بالتفصيل في `BUGFIX-PROMPT.md`.

### ٥) تجارب ناقصة
- الخطأ ١ ما انجرّب على Apple TV.
- أغلب التصاميم ما انجرّبت على Apple TV، والترجمة تحت الصورة ما انجرّبت على الآيفون ولا الوضع الأفقي ولا ترجمات ASS.
- شاشة التنزيلات الجديدة ما انصوّرت (ما فيه ملفات منزّلة على المحاكي).

## قواعد
- **ملفات ممنوع تعدّلها بدون ما تسألني:** `Lumen/Views/Home/TVFeed.swift`، `Lumen/Common/HomeFeed.swift`، `Lumen/Common/FeaturedContent.swift`، `Lumen/Services/UserFeed.swift`، `Lumen/Views/Home/HeroBanner.swift`، وجزء تحميل البانر والصفوف في `TVShell.swift` (حوالي السطر 560) و `BrowseViews.swift` (حوالي السطر 125).
- commits صغيرة باسم/إيميل من `gh api user` (noreply: `74823354+fahad00x@users.noreply.github.com`)، وأنهِ الرسالة بسطر Co-Authored-By.
- لا ترفع على GitHub ولا TestFlight بدون ما أطلب. لا تغيّر أي إعداد في حساب Apple، ولا تلغي أي شهادة.
- بعد كل إصلاح ابنِ التطبيقين:
  ```
  xcodebuild -project Lumen.xcodeproj -scheme LumenMobile -destination 'generic/platform=iOS Simulator' -derivedDataPath build/simios CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build
  xcodebuild -project Lumen.xcodeproj -scheme Lumen -destination 'generic/platform=tvOS Simulator' -derivedDataPath build/sim CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build
  ```
- بعد كل خطأ ارجع لي بـ: السبب الفعلي، الملفات اللي تغيّرت، هل انبنى التطبيقين، ووش جرّبت على المحاكي.

## ملاحظة
- فيه ١٣ commit على الفرع ما انرفعت على GitHub (`git status -sb` يبيّنها). قبل أي رفع اسألني.
- مجلد `build/` حجمه حوالي ١٨ جيجا.
