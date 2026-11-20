"""Prepare truthful App Store files without publishing or changing the app.

Only owner-input.json in the private output may hold reviewer contact details.
No Apple, SMTP, OAuth, session or account credentials are read by this script.
"""
import argparse
import csv
import gzip
import hashlib
import html
import json
import os
import plistlib
import shutil
import subprocess
import zipfile
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILT_APP = Path('/Users/shou/Library/Developer/Xcode/DerivedData/Runner-etwzcgrpxosoycenkbnytqkflsri/Build/Products/Debug-iphonesimulator/Runner.app')
SOURCES = {
 'review':'https://developer.apple.com/app-store/review/guidelines/',
 'complete_review':'https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review/',
 'metadata':'https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/',
 'screenshots':'https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/',
 'privacy':'https://developer.apple.com/app-store/app-privacy-details/',
 'privacy_manifest':'https://developer.apple.com/documentation/bundleresources/privacy-manifest-files',
 'required_reason':'https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api',
 'sdk_requirements':'https://developer.apple.com/support/third-party-SDK-requirements/',
 'deletion':'https://developer.apple.com/help/app-review/guideline-reference/5-1-1-account-deletion',
 'age_rating':'https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/',
 'encryption':'https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/',
 'individual_name':'https://developer.apple.com/help/app-store-connect/create-an-app-record/set-your-developer-name',
 'eu_trader':'https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/',
 'mpv_build':'https://github.com/media-kit/libmpv-darwin-build',
 'bunny_rights':'https://peach.blender.org/about/',
 'sintel_rights':'https://durian.blender.org/sharing/',
 'cc_by':'https://creativecommons.org/licenses/by/3.0/'
}
# ASC locale IDs differ from the app's language IDs.
COPY = {
'en-US':('Live streams, your playlist','Play your own live streams with a layout designed for iPhone and iPad.',
'''BobTV is a streaming player for sources you add yourself.

Add individual stream URLs or import a compatible BobTV data package. Organize supplied channels by category and view channel names and logos when available.

On iPhone, open channels from the bottom in portrait or from the side in landscape. iPad adapts its player and channel layout to the available space.

Programme information depends on the guide data associated with your sources. Playback quality and availability depend on the stream provider and your network.

An account is optional for current playback. Account settings include sign-out, account deletion and optional biometric unlocking on supported, enrolled mobile devices. Available sign-in methods are shown in the app.

The iOS channel list is empty on first launch. No paid subscription or recharge is offered in this version. Add only content you have permission to access.''',
'player,live,stream,playlist,HLS,channels,programme guide'),
'zh-Hans':('你的直播源，你的播放器','导入自己的播放源，使用适配 iPhone 和 iPad 的直播播放器。',
'''BobTV 是一款由你自行添加播放源的流媒体播放器。

支持逐条添加播放地址，或导入兼容的 BobTV 数据包；根据来源提供的信息整理频道分类、名称与台标。

iPhone 竖屏时从底部呼出频道抽屉，横屏时从侧边呼出。iPad 会根据屏幕方向调整播放器与频道布局。

节目指南取决于来源所关联的节目数据。播放画质、稳定性和可用性取决于视频来源与网络。

当前播放功能无需注册。账号页面提供退出登录、删除账号，以及已录入生物信息的兼容移动设备上的生物验证开关。可用登录方式以应用内显示为准。

iOS 播放器首次启动时频道列表为空。本版本不提供充值或付费订阅。请仅添加你有权访问的内容。''',
'播放器,直播,流媒体,播放列表,频道,节目单,HLS'),
'zh-Hant':('你的直播來源，你的播放器','匯入自己的播放來源，使用適配 iPhone 和 iPad 的直播播放器。',
'''BobTV 是由你自行加入播放來源的串流播放器。

逐條新增播放網址，或匯入相容的 BobTV 資料包；依來源資訊整理頻道分類、名稱及台標。

iPhone 直向時從底部開啟頻道抽屜，橫向時從側邊開啟。iPad 會依螢幕方向調整播放器與頻道配置。

節目表取決於來源提供的節目資料。播放畫質與可用性取決於串流來源及網路。

目前播放功能無需註冊。帳號頁提供登出、刪除帳號，以及已登錄生物資訊之相容行動裝置的生物辨識開關。可用登入方式以應用程式顯示為準。

iOS 播放器首次啟動時頻道列表為空。本版本不提供儲值或付費訂閱。請僅加入你有權存取的內容。''',
'播放器,直播,串流,播放列表,頻道,節目表,HLS'),
'ja':('自分の配信ソースを再生','iPhone と iPad に合わせた画面で、自分の配信ソースを再生。',
'''BobTV は、利用者が追加した配信ソースを再生するストリーミングプレーヤーです。

配信 URL を個別に追加するか、対応する BobTV データパッケージを読み込みます。ソースに含まれる分類、名前、ロゴを使ってチャンネルを整理できます。

iPhone の縦画面では下から、横画面では横からチャンネル一覧を開けます。iPad は画面の向きに応じてレイアウトを調整します。

番組情報はソースに関連付けられたガイドデータに依存します。画質と再生の可否は配信元とネットワークによって異なります。

現在の再生機能に登録は不要です。アカウント画面でログアウト、アカウント削除、対応する登録済みモバイル端末の生体認証を設定できます。利用可能なログイン方法はアプリ内に表示されます。

iOS 版の初回起動時、チャンネル一覧は空です。このバージョンではチャージや有料購読を提供しません。アクセスする権利のあるコンテンツを追加してください。''',
'プレーヤー,ライブ,配信,再生リスト,番組表,HLS'),
'fr-FR':('Vos flux, votre lecteur','Lisez vos propres flux dans une interface adaptée à iPhone et iPad.',
'''BobTV est un lecteur de flux que vous ajoutez vous-même.

Ajoutez des adresses de lecture ou importez un paquet de données BobTV compatible. Organisez les chaînes avec les catégories, noms et logos fournis par la source.

Sur iPhone, la liste s’ouvre depuis le bas en portrait et sur le côté en paysage. iPad adapte le lecteur et la liste à l’orientation.

Les informations des programmes dépendent des guides associés à vos sources. La qualité et la disponibilité dépendent du fournisseur et du réseau.

Le compte est facultatif pour la lecture actuelle. Ses réglages permettent la déconnexion, la suppression et le déverrouillage biométrique sur les appareils mobiles compatibles et configurés. Les méthodes de connexion disponibles sont affichées dans l’app.

Au premier lancement, la liste des chaînes iOS est vide. Cette version ne propose ni recharge ni abonnement payant. Ajoutez des contenus auxquels vous avez le droit d’accéder.''',
'lecteur,direct,flux,playlist,chaînes,HLS,programmes'),
'es-ES':('Tus emisiones, tu reproductor','Reproduce tus propias emisiones con una interfaz para iPhone y iPad.',
'''BobTV reproduce las fuentes de vídeo que tú añades.

Añade direcciones individuales o importa un paquete de datos BobTV compatible. Organiza los canales con las categorías, nombres y logotipos proporcionados por la fuente.

En iPhone, los canales se abren desde abajo en vertical y desde un lateral en horizontal. iPad adapta el reproductor y la lista a la orientación.

La guía depende de los datos asociados a las fuentes. La calidad y la disponibilidad dependen del proveedor y de la red.

La reproducción actual no requiere una cuenta. Sus ajustes permiten cerrar sesión, eliminar la cuenta y activar el desbloqueo biométrico en móviles compatibles con datos biométricos registrados. La app muestra los métodos de acceso disponibles.

La lista de canales de iOS está vacía al iniciar por primera vez. Esta versión no ofrece recargas ni suscripciones de pago. Añade solo contenido al que tengas derecho a acceder.''',
'reproductor,directo,emisiones,playlist,canales,HLS,programación'),
'ko':('내 스트림을 위한 플레이어','iPhone과 iPad에 맞춘 화면에서 직접 추가한 스트림을 재생하세요.',
'''BobTV는 사용자가 직접 추가한 소스를 재생하는 스트리밍 플레이어입니다.

재생 주소를 개별 추가하거나 호환되는 BobTV 데이터 패키지를 가져올 수 있습니다. 소스가 제공하는 분류, 이름, 로고로 채널을 정리하세요.

iPhone 세로 화면에서는 아래에서, 가로 화면에서는 옆에서 채널 목록을 엽니다. iPad는 화면 방향에 맞춰 레이아웃을 조정합니다.

프로그램 정보는 소스에 연결된 편성표에 따라 달라집니다. 화질과 재생 가능 여부는 공급자 및 네트워크에 따라 달라집니다.

현재 재생 기능에는 가입이 필요하지 않습니다. 계정 화면에서 로그아웃, 계정 삭제, 등록된 생체 정보를 지원하는 모바일 기기의 생체 잠금 해제를 설정할 수 있습니다. 사용 가능한 로그인 방식은 앱에 표시됩니다.

iOS 버전의 첫 실행에서는 채널 목록이 비어 있습니다. 이 버전에는 충전이나 유료 구독이 없습니다. 접근 권한이 있는 콘텐츠만 추가하세요.''',
'플레이어,라이브,스트림,재생목록,채널,HLS')
}


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value if isinstance(value,str) else json.dumps(value,ensure_ascii=False,indent=2)+'\n')


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(out):
    app=BUILT_APP
    if not app.exists():return {'available':False}
    manifests=[]
    for path in app.rglob('PrivacyInfo.xcprivacy'):
        manifests.append({'path':str(path.relative_to(app)),'sha256':sha(path),'content':plistlib.loads(path.read_bytes())})
    info=plistlib.loads((app/'Info.plist').read_bytes())
    native=[]
    for name in ['Mpv','Avcodec','Avformat','Avfilter','Mbedtls','Mbedcrypto','Mbedx509']:
        file=app/'Frameworks'/(name+'.framework')/name
        if not file.exists():continue
        lines=subprocess.check_output(['strings',str(file)],text=True).splitlines()
        evidence=[line for line in lines if ('-Dgpl=' in line or ' license: ' in line or '--disable-decoders' in line or (line.startswith('--disable-autodetect')))]
        native.append({'framework':name,'sha256':sha(file),'evidence':evidence[:3]})
    write(out/'technical/native-libraries.json',native)
    write(out/'technical/bundled-privacy-manifests.json',manifests)
    notices=app/'Frameworks/App.framework/flutter_assets/NOTICES.Z'
    if notices.exists():
        try:body=gzip.decompress(notices.read_bytes()).decode()
        except (OSError,UnicodeDecodeError):body=notices.read_text(errors='replace')
        write(out/'rights/THIRD-PARTY-NOTICES.txt',body)
    for file in (app/'NativeAudioSpectrum').glob('*'):
        if file.is_file() and ('COPYING' in file.name or 'NOTICE' in file.name or 'LICENSE' in file.name):
            target=out/'rights/native'/file.name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(file,target)
    return {'available':True,'path':str(app),'info':{k:info.get(k) for k in ['CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion','UIDeviceFamily','NSAppTransportSecurity','NSFaceIDUsageDescription','NSSpeechRecognitionUsageDescription']},'binaryKind':'simulator debug, not an App Store archive','infoSha256':sha(app/'Info.plist'),'privacyManifestCount':len(manifests),'appRootManifestPresent':(app/'PrivacyInfo.xcprivacy').exists()}


def pdf(out, summary):
    from reportlab.platypus import SimpleDocTemplate,Paragraph,Spacer,Table,TableStyle,PageBreak
    from reportlab.lib.styles import getSampleStyleSheet,ParagraphStyle
    from reportlab.lib import colors
    from reportlab.lib.enums import TA_LEFT
    from reportlab.lib.pagesizes import A4
    styles=getSampleStyleSheet()
    styles.add(ParagraphStyle(name='BodyReview',fontName='Helvetica',fontSize=10,leading=15,spaceAfter=10,textColor=colors.HexColor('#273147')))
    styles.add(ParagraphStyle(name='HeroReview',fontName='Helvetica-Bold',fontSize=27,leading=32,textColor=colors.HexColor('#28305a'),spaceAfter=18))
    items=[]
    def text(s,style='BodyReview'):items.append(Paragraph(html.escape(s),styles[style]))
    text('BobTV | App Review Pack','HeroReview');text('Prepared: '+summary['preparedAtTokyo']);text('DRAFT. Not authorized for submission until the readiness gate passes.')
    text('1. Product and review scope','Heading2')
    text('Universal iPhone/iPad streaming player. Users add individual URLs or compatible data packages. Current playback remains available without signing in. There are no purchases, recharge or subscriptions in this version.')
    text('The iOS source policy skips the bundled public catalog and public catalog synchronization. Programme guides, image delivery and subtitle services have network dependencies that must remain visible to reviewers.')
    text('2. Included materials','Heading2')
    for s in ['Seven locale metadata sets and English/Chinese review notes.','Private review contact sheet and separate account-access instructions.','Privacy data worksheet, permission notes and observed SDK manifests.','Encryption, age-rating, accessibility and distribution worksheets.','Licensed demo provenance and third-party software notices.','Original simulator screenshots with size, hash and provenance manifests.']:
        text(s)
    items.append(PageBreak());text('Submission readiness','HeroReview')
    for issue in summary['blockers']:text(issue['id']+': '+issue['summary'])
    items.append(PageBreak());text('Review walkthrough','HeroReview')
    for heading,body in [
      ('Guest playback','Launch with no imported sources. Add a single permitted stream or a compatible .bobtv data package using the regular source-management interface. A public review demonstration URL is still required.'),
      ('Channels and layout','On iPhone, open the channel drawer from the bottom in portrait or from the side in landscape. iPad changes its player/channel arrangement with orientation. Use only actual screenshots from the final submitted build.'),
      ('Data packages','Packages contain supported data fields such as category, route, logo and guide references. They do not install executable code. All supported import and sync features must be disclosed, including any regional catalog functionality if it is later connected.'),
      ('Accounts and deletion','Email verification, sign-out, deletion and an optional mobile biometric lock are implemented. Google and Apple configuration is deferred. The final build must expose fully reviewable, working account paths without reviewer-only bypasses.'),
      ('Privacy and permissions','Face and fingerprint templates stay with the OS. On-device speech alignment is optional and must be verified for supported languages. Network metadata/EPG/subtitle requests and optional diagnostics require final disclosure matching the archive.'),
      ('Rights','Demo animation trailers use CC BY 3.0, with attribution and transformation notes. Generated signals/logos are original CC0 material. This only documents the included demo and does not grant rights to other server catalogs.')]:
        text(heading,'Heading2');text(body)
    text('Primary official references','Heading2')
    for key in ['complete_review','privacy','screenshots','encryption','individual_name']:
        items.append(Paragraph('<link href="'+SOURCES[key]+'">'+html.escape(key.replace('_',' '))+'</link>',styles['BodyReview']))
    def footer(canvas,doc):
        canvas.setFillColor(colors.HexColor('#758098'));canvas.setFont('Helvetica',8);canvas.drawString(42,24,'BobTV | Preparation only | Private review workflow');canvas.drawRightString(A4[0]-42,24,str(doc.page))
    SimpleDocTemplate(str(out/'BobTV-App-Review-Overview.pdf'),pagesize=A4,rightMargin=42,leftMargin=42,topMargin=42,bottomMargin=42).build(items,onFirstPage=footer,onLaterPages=footer)


def build(out):
    if out == ROOT or ROOT in out.parents:raise ValueError('Choose a private output directory outside the repository')
    out.mkdir(parents=True,exist_ok=True);out.chmod(0o700)
    now=datetime.now(timezone.utc).isoformat()
    head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    status=subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True)
    # Record state without exporting unrelated uncommitted source or secrets.
    write(out/'technical/source-snapshot.json',{'head':head,'workingTreeChanges':[line[3:] for line in status.splitlines()],'releaseFrozen':False,'capturedAt':now})
    observation=inventory(out);write(out/'technical/observed-build.json',observation)
    write(out/'sources.json',{'checkedAt':now,'primarySources':SOURCES})
    for locale,(subtitle,promotion,description,keywords) in COPY.items():
        data={'locale':locale,'name':'BobTV','subtitle':subtitle,'promotionalText':promotion,'description':description,'keywords':keywords,'supportUrl':None,'marketingUrl':'https://bobtv.briconbric.com/','privacyPolicyUrl':'https://bobtv.briconbric.com/privacy','whatsNew':{'en-US':'Initial iPhone and iPad submission: user-added sources, adaptive channels and optional accounts.','zh-Hans':'首次提交 iPhone 和 iPad 版本：自行添加播放源、自适应频道选择和可选账号。','zh-Hant':'首次提交 iPhone 和 iPad 版本：自行加入播放來源、自適應頻道選擇和選用帳號。','ja':'iPhone と iPad 向け初回申請。配信ソースの追加、画面に適応するチャンネル選択、任意のアカウント機能。','fr-FR':'Première version iPhone et iPad : sources personnelles, sélection adaptative des chaînes et compte facultatif.','es-ES':'Primera versión para iPhone y iPad: fuentes propias, selección adaptable de canales y cuentas opcionales.','ko':'iPhone 및 iPad 첫 제출: 직접 소스 추가, 화면에 맞춘 채널 선택 및 선택적 계정 기능.'}[locale],'status':'DRAFT_NOT_APPROVED_FOR_SUBMISSION'}
        if not(len(subtitle)<=30 and len(promotion)<=170 and len(description)<=4000 and len(keywords.encode('utf-8'))<=100):raise ValueError('Metadata length: '+locale)
        write(out/'store-metadata'/locale/'metadata.json',data)
        for field in ['name','subtitle','promotionalText','description','keywords','whatsNew']:write(out/'store-metadata'/locale/(field+'.txt'),data[field]+'\n')
    write(out/'store-metadata/app-information.json',{'bundleId':'com.briconbric.bobtv','skuCandidate':'BOBTV-IOS-UNIVERSAL','platform':'iOS','deviceFamilies':['iPhone','iPad'],'primaryLanguageCandidate':'zh-Hans','primaryCategoryCandidate':'ENTERTAINMENT','priceCandidate':'FREE','copyright':None,'developerType':'INDIVIDUAL','sellerName':'Use legal name verified by Apple; do not invent a company','versionObserved':'1.3.1','buildObserved':'1','appStoreVersionConfirmed':False,'releaseModeCandidate':'MANUAL','availabilityConfirmed':False,'customEula':'Not prepared; use Apple standard EULA unless another agreement is approved'})
    contacts=out/'private/owner-input.json'
    owner=json.loads(contacts.read_text()) if contacts.exists() else {}
    write(out/'private/app-review-contact.json',{'status':'PRIVATE_DRAFT','contactName':owner.get('name'),'email':owner.get('email'),'phoneAsSupplied':owner.get('phone'),'phoneFormatConfirmed':False,'phoneE164Candidate':owner.get('phoneE164Candidate'),'company':None,'accountType':'Individual','publicCopyrightOwnerConfirmed':False,'supportEmailPublicationApproved':False})
    write(out/'private/account-access.json',{'guestPlaybackRequiresSignIn':False,'accountFeaturesRequireSignIn':True,'reviewAccountEmail':None,'reviewAccountPassword':None,'reviewAccountStatus':'NOT_PROVISIONED','emailOtp':'No static code or reviewer bypass exists. A working verification path and full reviewer access must be arranged.','googleApple':'Configuration explicitly deferred by owner. Do not represent as working or submit unfinished disabled paths without a final scope decision.','administratorCredentials':'Never provide owner admin credentials to reviewers.'})
    (out/'private').chmod(0o700)
    for p in (out/'private').glob('*'):p.chmod(0o600)
    for name in ['review-notes-en.txt','review-notes-zh.txt','privacy-data-map.csv','privacy-notes.md','export-compliance.md','age-rating.md','accessibility.md','rights-and-license.md','submission-checklist.md','permissions.md']:
        source=ROOT/'docs/app-store'/name
        if source.exists():write(out/('review/'+name if name.startswith('review-notes') else name),source.read_text())
    demo=ROOT/'docs/resource-package/examples/live-demo'
    for name in ['NOTICE.txt','licenses/CC-BY-3.0-NOTICE.txt','licenses/Apache-2.0.txt']:
        dest=out/'rights'/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(demo/name,dest)
    shutil.copy2(ROOT/'LICENSE',out/'rights/BOBTV-SOURCE-LICENSE.txt')
    package=json.loads((demo/'local-hls.bobtv').read_text())
    def replace(v):
        if isinstance(v,str):return v.replace('http://127.0.0.1:18767','https://REVIEW-HOST-REQUIRED.invalid/review-demo')
        if isinstance(v,list):return [replace(x) for x in v]
        if isinstance(v,dict):return {k:replace(x) for k,x in v.items()}
        return v
    write(out/'review/demo-public-URL-REQUIRED.bobtv',replace(package))
    write(out/'review/demo-access.json',{'status':'PUBLIC_HTTPS_NOT_DEPLOYED','packageUrl':None,'expectedChannels':3,'expectedCategories':2,'protocol':'HLS live, not static VOD','testPlan':'Verify moving media sequence and fresh segment decoding from an external network; record uptime and HTTPS reachability.','templateFile':'demo-public-URL-REQUIRED.bobtv'})
    server=ROOT.parents[1]/'outputs/open-live-demo-20261120/bobtv-hls-live-server-example.zip'
    if server.exists():shutil.copy2(server,out/'review/bobtv-hls-live-server-example.zip')
    icon=ROOT/'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png'
    (out/'artwork').mkdir(exist_ok=True);shutil.copy2(icon,out/'artwork/AppIcon-1024.png')
    from PIL import Image
    image=Image.open(icon);write(out/'artwork/icon-check.json',{'size':list(image.size),'mode':image.mode,'alphaPresent':'A' in image.mode,'sha256':sha(icon),'designOwnership':'Confirm actual rights before publication'})
    issues=[
      ('BUNDLED_CATALOG_ASSETS','Legacy compressed catalog/snapshot assets are physically present in the iOS bundle despite the empty initial list. Exclude them or verify all applicable distribution rights before submission.'),
      ('FINAL_SOURCE','Freeze the final source and review the uncommitted regional-catalog changes; screenshots/builds must match that source.'),
      ('SIGNED_ARCHIVE','No valid distribution signing identity was found on this Mac. A device arm64 App Store archive, dSYMs and App Store Connect validation receipt are required.'),
      ('NATIVE_SIGN_IN','The current adapter launches an external default browser; iOS sign-in needs an appropriate in-app/native flow before submission, following Apple account guidance.'),
      ('REVIEW_ACCESS','Working ordinary reviewer account access is not provisioned; provider configuration is deferred and SMTP delivery needs real verification.'),
      ('PUBLIC_LIVE_DEMO','The licensed HLS example has no verified public HTTPS endpoint; localhost URLs are unusable by App Review.'),
      ('SUPPORT_URL','A public support page with an approved contact address has not been verified. The marketing homepage alone does not establish this requirement.'),
      ('PRIVACY_FINAL','Confirm privacy labels, direct and relay data flows, app-root privacy manifest, required-reason APIs and final archive SDK signatures.'),
      ('IDENTITY_FIELDS','Confirm public copyright ownership/name, contact phone formatting, seller membership identity and territory-specific declarations.'),
      ('FINAL_BINARY_QA','Complete physical-device audio/biometric testing, account deletion, stream import, subtitle/network failure paths and production signing checks.'),
      ('QUESTIONNAIRES','Complete encryption, age rating, accessibility and territory forms from the final build; no blanket exemption or age rating is asserted.')]
    summary={'preparedAt':now,'preparedAtTokyo':datetime.now(ZoneInfo('Asia/Tokyo')).strftime('%Y-%m-%d %H:%M JST'),'readyToSubmit':False,'sourceHead':head,'blockers':[{'id':key,'summary':value,'resolved':False} for key,value in issues],'materialStatus':'Prepared drafts and evidence; not an uploaded or accepted submission'}
    write(out/'readiness.json',summary)
    pdf(out,summary)
    write(out/'START-HERE.txt','BobTV App Store 审核材料\n\n先阅读 BobTV-App-Review-Overview.pdf 和 readiness.json。\nstore-metadata 为七语言草稿；private 为仅供审核与本人使用的联系人/账号资料。\n所有尚未确认的字段保留为空，不包含虚构的签名、审核账号或公网直播地址。\n运行 validate_review_bundle.py --strict 会阻止这些状态直接提交。\n')
    # A real, conservative manifest draft; not copied into the app automatically.
    draft={'NSPrivacyTracking':False,'NSPrivacyTrackingDomains':[],'NSPrivacyAccessedAPITypes':[{'NSPrivacyAccessedAPIType':'NSPrivacyAccessedAPICategoryUserDefaults','NSPrivacyAccessedAPITypeReasons':['CA92.1']},{'NSPrivacyAccessedAPIType':'NSPrivacyAccessedAPICategoryFileTimestamp','NSPrivacyAccessedAPITypeReasons':['C617.1']}],'NSPrivacyCollectedDataTypes':[]}
    (out/'technical/PrivacyInfo.xcprivacy.example').write_bytes(plistlib.dumps(draft))
    for source in (ROOT/'docs/app-store').glob('support-*.template.html'):
        write(out/'web-drafts'/source.name.replace('.template',''),source.read_text())
    (out/'technical/ExportOptions.template.plist').write_bytes(plistlib.dumps({'method':'app-store-connect','teamID':'TEAM_ID_REQUIRED','signingStyle':'automatic','destination':'export','uploadSymbols':True,'stripSwiftSymbols':True}))
    write(out/'technical/PRIVACY-DRAFT-WARNING.txt','Example only. Collected-data entries are intentionally incomplete. Do not insert this file into a submitted app unchanged. Confirm exact collection, linkage, purposes and all required-reason categories from the final archive. No-data/No-tracking status is not certified by generating this file.\n')
    return summary


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    print(json.dumps(build(args.output.resolve()),ensure_ascii=False))


if __name__=='__main__':main()
