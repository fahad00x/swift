# تثبيت Lumen على Apple TV عبر TestFlight

هذا الدليل يجهّز رفع التطبيق تلقائياً من GitHub Actions إلى TestFlight، **بدون Mac وبدون شهادات يدوية**.
كل اللي تحتاجه: حساب Apple Developer مفعّل، و٤ قيم تحطها في GitHub.

| القيمة | اسم الـ Secret في GitHub | من وين تجيبها |
|---|---|---|
| Key ID | `ASC_KEY_ID` | الخطوة ٤ |
| Issuer ID | `ASC_ISSUER_ID` | الخطوة ٤ |
| محتوى ملف ‎`.p8` | `ASC_KEY_P8` | الخطوة ٤ |
| Team ID | `APPLE_TEAM_ID` | الخطوة ١ |

---

## ١) Team ID

1. افتح <https://developer.apple.com/account> وسجّل دخول.
2. انزل إلى **Membership details**.
3. انسخ **Team ID**: عشرة أحرف وأرقام إنجليزية كبيرة، مثل `AB12CD34EF`.

## ٢) تسجيل الـ Bundle ID

1. من <https://developer.apple.com/account/resources/identifiers/list> اضغط **+**.
2. اختر **App IDs**، ثم **Continue**، ثم **App**، ثم **Continue**.
3. **Description**: ‏`Lumen`
4. **Bundle ID**: اختر **Explicit** واكتب بالضبط: ‏`com.fahad00x.lumen`
5. تحت **Capabilities** فعّل ✅ **iCloud** فقط (لمزامنة المستخدمين، شوف الخطوة ٢-ب). اضغط **Continue** ثم **Register**.

## ٢-ب) iCloud Container (لمزامنة المستخدمين)

بيانات المستخدمين داخل التطبيق (التقدّم، المشاهَد، قائمتي، المكتبات) تنحفظ في CloudKit داخل Container اسمه `iCloud.com.fahad00x.lumen`.

**وش يسوي الـ workflow تلقائياً:**
- يفعّل قدرة **iCloud** على الـ Bundle ID عن طريق App Store Connect API (خطوة *Enable iCloud capability on the App ID*).
- يحط صلاحيات iCloud في الأرشيف، وخطوة التصدير (`-allowProvisioningUpdates`) تسوي ملف التوقيع اللي فيه iCloud.

**وش ما يقدر يسويه:** واجهة App Store Connect API ما فيها إنشاء iCloud Container ولا ربطه بالـ Bundle ID. فهذي تسويها **مرة وحدة بس** يدوياً:

1. افتح <https://developer.apple.com/account/resources/identifiers/list/cloudContainer> (أو من **Identifiers** اختر من القائمة فوق يمين **iCloud Containers**).
2. اضغط **+**، ثم اختر **iCloud Containers**، ثم **Continue**.
3. **Description**: ‏`Lumen`
4. **Identifier**: اكتب بالضبط: ‏`iCloud.com.fahad00x.lumen` ثم **Continue** ثم **Register**.
5. ارجع لقائمة **Identifiers** واختر **App IDs**، وافتح `com.fahad00x.lumen`.
6. تأكد إن ✅ **iCloud** مفعّل، واختر **Include CloudKit support (requires Xcode 6)**، ثم اضغط **Edit** (أو **Configure**) جنبه.
7. علّم ✅ على `iCloud.com.fahad00x.lumen` واضغط **Continue** ثم **Save**. إذا طلع تحذير إن ملفات التوقيع بتنلغى، وافق، والـ workflow يسوي ملفات جديدة تلقائياً.

### نشر مخطط CloudKit (Schema) لبيئة الإنتاج
نسخ TestFlight تستخدم بيئة **Production** في CloudKit، وهذي ما تنشئ أنواع السجلات تلقائياً. لازم تنشرها **مرة وحدة**:

1. افتح <https://icloud.developer.apple.com/dashboard> واختر `iCloud.com.fahad00x.lumen`.
2. **الطريقة الأسهل (من Mac أو Terminal فيه Xcode):** أنشئ *Management Token* من **Settings ← Tokens** في نفس الموقع، ثم:
   ```bash
   xcrun cktool save-token --type management
   xcrun cktool import-schema --team-id <TEAM_ID> --container-id iCloud.com.fahad00x.lumen \
     --environment development --file Shared/Sync/schema.ckdb
   ```
3. **أو يدوياً من المتصفح:** ‏**CloudKit Database ← Schema ← Record Types ← +**، وأنشئ الأنواع والحقول الموجودة في الملف [`Shared/Sync/schema.ckdb`](Shared/Sync/schema.ckdb) بنفس الأسماء والأنواع (`STRING` = String، `INT64` = Int(64)، `TIMESTAMP` = Date/Time، `REFERENCE` = Reference):
   - `Profile`: ‏profileID، name، symbol، colorHex، isKids، isOwner، pinHash، scopes، knownSections، genres، preferredAudioLanguage، preferredSubtitleLanguage، subtitlesOff، settings، createdAt، modifiedAt
   - `MediaState`: ‏profileID، profile، ratingKey، type، showKey، seasonKey، sectionKey، sortIndex، genres، offsetMs، durationMs، watched، lastViewedAt، audioStreamID، subtitleStreamID، modifiedAt
   - `WatchlistItem`: ‏profileID، profile، ratingKey، type، sectionKey، addedAt، modifiedAt
   - `cloudkit.share` (لمشاركة المستخدم مع حساب iCloud ثاني): اضغط **+** واكتب الاسم `cloudkit.share` بس، وحقوله تنضاف لحالها
4. بعدها من الصفحة الرئيسية للـ Container اضغط **Deploy Schema Changes…** ثم **Deploy** إلى Production.

### إضافة حقل `settings` (مرة وحدة، للنسخ من البناء ١٠ وطالع)
إعدادات كل مستخدم (مكتبات الشريط الجانبي، تخطي المقدمة، الحلقة التالية) تنحفظ في حقل جديد اسمه `settings` في نوع `Profile`. تقدر تسويها من متصفح الجوال (Safari: ‏**aA ← Request Desktop Website** إذا الصفحة ضيقة):

1. افتح <https://icloud.developer.apple.com> وسجّل دخول بحساب المطوّر، ثم **CloudKit Database** واختر `iCloud.com.fahad00x.lumen`.
2. فوق تأكد إن البيئة **Development**.
3. من القائمة: **Schema ← Record Types ← Profile**.
4. اضغط **+ Add Field** (أو زر +)، الاسم `settings` والنوع **String**، ثم **Save**.
5. ارجع لصفحة الـ Container واضغط **Deploy Schema Changes…** ← راجع إن التغيير «Profile: settings» ← **Deploy**.

> قبل هالخطوة التطبيق يشتغل عادي ويحفظ كل شي ثاني، بس هالإعدادات تبقى على الجهاز نفسه ولا تتزامن.

> **إذا ما سويت هذي الخطوات:** التطبيق يشتغل عادي، والمستخدمين وبياناتهم تنحفظ على الآبل تي في نفسه بس، وفي الإعدادات تحت «iCloud» تطلع رسالة توضّح السبب. وإذا فشل التوقيع بسبب الـ Container، شغّل الـ workflow مع إلغاء خيار **icloud** عشان ترفع نسخة بدون iCloud لين تخلص الإعداد.
> **بديل تلقائي:** إذا عندك Apple TV مسجّل في حسابك (Devices)، شغّل الـ workflow مع خيار **signed_archive**؛ التوقيع التلقائي في Xcode ينشئ الـ Container ويربطه بنفسه.

## ٣) إنشاء التطبيق في App Store Connect

1. افتح <https://appstoreconnect.apple.com> ثم **Apps**، ثم **+**، ثم **New App**.
2. عبّي الحقول:
   - **Platforms**: ‏✅ **tvOS** و ✅ **iOS** (تطبيق الآبل تي في والآيفون تطبيق واحد بنفس الـ Bundle ID)
   - **Name**: ‏`Lumen`. الاسم لازم يكون فريد في كل الستور، فإذا قال إنه محجوز اكتب مثلاً `Lumen Player Home`. الاسم هنا ما يأثر على شي، والتطبيق ما راح يُنشر.
   - **Primary Language**: ‏Arabic
   - **Bundle ID**: اختر `com.fahad00x.lumen`. إذا ما ظهر، انتظر دقائق بعد الخطوة ٢ وحدّث الصفحة.
   - **SKU**: أي نص، مثل `lumen-tvos`
   - **User Access**: ‏Full Access
3. اضغط **Create**.

> **إذا كان التطبيق موجود من قبل لـ tvOS فقط:** افتح **Apps ← Lumen**، ومن القائمة الجانبية تحت اسم المنصة اضغط **+ Add Platform** (أو **Platforms**) واختر **iOS**. بدون هذي الخطوة يفشل رفع نسخة الآيفون برسالة مثل `No suitable application records were found` أو إن المنصة غير موجودة.

> ⚠️ **مهم:** ادخل **Business** (أو **Agreements, Tax, and Banking**) ووافق على أي اتفاقية معلّقة، خصوصاً *Apple Developer Program License Agreement*. الرفع يفشل لو فيه اتفاقية ما وافقت عليها.
> المعلومات البنكية والضريبية **مو مطلوبة** لأن التطبيق مجاني ولـ TestFlight فقط.

## ٤) إنشاء App Store Connect API Key

1. في App Store Connect افتح **Users and Access**، ثم تبويب **Integrations**، ثم **App Store Connect API**، ثم **Team Keys**.
   - أول مرة بيطلب منك **Request Access**. وافق، وصاحب الحساب (أنت) يتفعّل له فوراً.
2. اضغط **Generate API Key** (أو **+**):
   - **Name**: ‏`GitHub Actions`
   - **Access**: ‏**Admin**. ضروري: الصلاحيات الأقل ما تسمح بإنشاء شهادة التوقيع السحابية (Cloud Managed Distribution Certificate) وملفات الـ Provisioning تلقائياً.
3. بعد الإنشاء:
   - انسخ **Issuer ID** من أعلى الصفحة (شكله `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`)، هذا قيمة **`ASC_ISSUER_ID`**.
   - انسخ **Key ID** من جدول المفاتيح (عشرة أحرف)، هذا قيمة **`ASC_KEY_ID`**.
   - اضغط **Download API Key** ونزّل الملف `AuthKey_XXXXXXXXXX.p8`. ⚠️ **ينزل مرة وحدة بس**، احتفظ فيه بمكان آمن.

### نسخ محتوى ملف ‎.p8
الـ Secret ‏`ASC_KEY_P8` هو **النص الكامل** اللي داخل الملف، ويبدأ وينتهي هكذا:
```
-----BEGIN PRIVATE KEY-----
MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQg...
-----END PRIVATE KEY-----
```
- **من الآيفون:** افتح تطبيق **الملفات (Files)**، واضغط مطولاً على الملف، واختر **إعادة تسمية** وغيّر الامتداد إلى `.txt`. بعدها افتحه وانسخ النص كامل.
- **من ويندوز:** افتحه بـ Notepad وانسخ الكل.

> يقبل الـ workflow أيضاً المحتوى مشفّراً بـ base64 إذا كان أسهل لك.

## ٥) إضافة الـ Secrets في GitHub

1. افتح المستودع: <https://github.com/fahad00x/swift>
2. اذهب إلى **Settings**، ثم **Secrets and variables**، ثم **Actions**، ثم **New repository secret**.
3. أضف الأربعة واحد واحد (الاسم بالحروف الإنجليزية الكبيرة بالضبط):

| Name | Secret |
|---|---|
| `ASC_KEY_ID` | Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | النص الكامل لملف ‎`.p8` |
| `APPLE_TEAM_ID` | Team ID |

> من الجوال: صفحة Settings ما تظهر في تطبيق GitHub. افتح github.com في Safari، واختر من قائمة **ᴀA** ‏**طلب موقع سطح المكتب (Request Desktop Website)**.

## ٦) تشغيل الـ workflow من الجوال

**من تطبيق GitHub (iOS/Android):**
1. افتح المستودع `fahad00x/swift`، ثم **Actions**.
2. اختر **TestFlight**، ثم **Run workflow**، وتأكد أن الفرع **main**. من **platforms** اختر `both` (الافتراضي) أو `tvOS` أو `iOS` بس، ثم **Run workflow**.
   - كل منصة تُبنى وتُرفع في Job منفصل، فإذا فشلت وحدة ما تأثر على الثانية.

**أو من Safari:** ‏github.com/fahad00x/swift، ثم **Actions**، ثم **TestFlight**، ثم **Run workflow**.

- يستغرق تقريباً ١٠–٢٠ دقيقة. إذا نجح تشوف ✅ وملخص فيه رقم النسخة.
- بعدها App Store Connect يعالج النسخة من ٥ إلى ٣٠ دقيقة، ويوصلك إيميل لما تجهز.
- رقم البناء (Build) يُؤخذ تلقائياً من رقم التشغيل، فكل تشغيل جديد يعطي رقم أعلى.
- **تلقائياً:** يشتغل كل شهرين (يوم ١ الساعة ٣ فجراً UTC) عشان تبقى عندك نسخة صالحة. نسخ TestFlight تنتهي بعد ٩٠ يوم.

## ٧) إضافة المختبرين (Internal Testers)

**أ) أضف أي شخص ثاني كمستخدم في الفريق** (صاحب الحساب موجود أصلاً بصفته Account Holder):
1. App Store Connect، ثم **Users and Access**، ثم **+**.
2. اكتب اسمه وإيميل الـ Apple ID حقه.
3. **Roles**: اختر **Marketing** (أو **Developer**). تكفي لـ TestFlight وما تعطي صلاحيات حساسة.
4. تحت **Apps** اختر **Lumen** فقط (أو All Apps)، ثم **Invite**.
5. لازم يقبل الدعوة من الإيميل اللي يوصله.

**ب) أنشئ مجموعة اختبار داخلية:**
1. **Apps**، ثم **Lumen**، ثم تبويب **TestFlight**.
2. من القائمة الجانبية، بجانب **Internal Testing**، اضغط **+** وسمّها مثلاً `Testers`.
3. فعّل ✅ **Enable automatic distribution** عشان كل نسخة جديدة توصلكم تلقائياً.
4. اضغط **Add Testers** (أو **+** بجانب Testers) واختر المختبرين.

**ج) على الآيفون:** نزّل تطبيق **TestFlight** من App Store، وسجّل بنفس الـ Apple ID المضاف كـ Tester، ويظهر **Lumen** فيه. نفس مجموعة الاختبار تشمل الآيفون والآبل تي في.

**د) على الآبل تي في:**
1. نزّل تطبيق **TestFlight** من App Store على الآبل تي في.
2. افتحه وهو مسجّل بنفس الـ Apple ID المضاف كـ Tester. حساب الـ App Store في الآبل تي في من الإعدادات، ثم **المستخدمون والحسابات**.
3. يظهر **Lumen**. اضغط **Install**.

> على جهاز Apple TV فيه أكثر من مستخدم (Multiple Users)، كل مختبر مضاف يقدر يثبّته من حسابه.

---

## حل المشاكل

| الرسالة في الـ workflow | السبب والحل |
|---|---|
| `Missing GitHub secrets: ...` | واحد من الـ Secrets ناقص أو اسمه غلط. راجع الخطوة ٥. |
| `Invalid APPLE_TEAM_ID` | حطيت شي غير الـ Team ID المكوّن من ١٠ خانات. |
| `Invalid ASC_KEY_P8` | انسخ الملف كامل مع سطري BEGIN وEND. |
| `No profiles for 'com.fahad00x.lumen' were found` | الـ Bundle ID ما انسجّل (الخطوة ٢)، أو المفتاح صلاحيته مو Admin. |
| `Cloud signing permission error` / `not permitted to create certificates` | صلاحية المفتاح لازم تكون **Admin**. |
| `Unable to authenticate` / `401` | Key ID أو Issuer ID غلط، أو المفتاح انلغى. |
| `agreement` / `PLA` | وافق على الاتفاقيات في App Store Connect، ثم Business. |
| `The bundle version must be higher` / `Redundant Binary Upload` | رقم البناء مستخدم مسبقاً، وهذا يصير لو أعدت تشغيل (Re-run) نفس التشغيل. شغّل **Run workflow** جديد. |
| `No suitable application records were found` | التطبيق ما انشأ في App Store Connect (الخطوة ٣)، أو الـ Bundle ID مختلف. |
| `iCloud container` / `icloud-container-identifiers` / `doesn't include the iCloud capability` | الـ Container ما انشأ أو ما انربط بالـ Bundle ID. سوِّ الخطوة ٢-ب، أو شغّل مع إلغاء **icloud**. |
| في التطبيق: «مخطط CloudKit غير منشور في بيئة الإنتاج» | انشر الـ Schema (آخر الخطوة ٢-ب). |
| في التطبيق: «سجّل الدخول إلى iCloud» | سجّل دخول iCloud في الآبل تي في: الإعدادات ← المستخدمون والحسابات ← iCloud. |
| فشل التصدير (Export) لأسباب توقيع أخرى | شغّل الـ workflow مع تفعيل خيار **signed_archive**. هذا يوقّع الأرشيف أثناء البناء بطريقة Xcode التقليدية. |

عند الفشل يرفع الـ workflow ملفات السجل (`testflight-logs`) في صفحة التشغيل، تقدر ترسلها لي.

## ملاحظات
- **دقائق macOS:** في المستودعات الخاصة كل دقيقة macOS تُحسب بـ ١٠ دقائق من رصيد GitHub المجاني (٢٠٠٠ دقيقة شهرياً، يعني تقريباً ٢٠٠ دقيقة macOS). كل رفع يستهلك تقريباً ١٠–٢٠ دقيقة. لهذا `build.yml` يشتغل فقط على `main` والـ Pull Requests.
- **المستودع العام:** GitHub يوقف الـ workflows المجدولة تلقائياً في المستودعات العامة إذا ما صار فيها أي نشاط لمدة ٦٠ يوم. لو صار هذا، فعّلها من **Actions**، ثم **TestFlight**، ثم **Enable workflow**.
- **التشفير:** ‏`ITSAppUsesNonExemptEncryption = NO` موجود في Info.plist، فما راح يسألك App Store Connect عن Export Compliance مع كل نسخة.
- **الأيقونة:** تصميم مؤقت بسيط في `Lumen/Assets.xcassets`. تقدر تستبدل الصور بنفس الأبعاد متى ما بغيت.
