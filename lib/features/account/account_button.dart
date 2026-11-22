import 'regional_catalog_button.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/platform_info.dart';
import '../../data/services/installation_registration_policy.dart';
import '../../core/i18n/app_language.dart';
import 'account_service.dart';

class AccountButton extends StatefulWidget {
  const AccountButton({super.key, this.compact = false});
  final bool compact;
  @override
  State<AccountButton> createState() => _AccountButtonState();
}

class _AccountButtonState extends State<AccountButton> {
  final account = AccountService.instance;
  @override
  void initState() {
    super.initState();
    unawaited(account.initialize());
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (!InstallationRegistrationPolicy.instance.legacyAccess)
        RegionalCatalogButton(
          onSignIn: () => showDialog<void>(
            context: context,
            builder: (_) => const _AccountDialog(),
          ),
        ),
      ListenableBuilder(
        listenable: account,
        builder: (context, _) => widget.compact
            ? IconButton(
                key: const ValueKey('account-entry'),
                tooltip: AppMessages.text(
                  context,
                  account.loggedIn ? '我的账号' : '注册 / 登录',
                ),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _AccountDialog(),
                ),
                icon: Icon(
                  account.loggedIn
                      ? Icons.account_circle
                      : Icons.person_outline,
                ),
              )
            : TextButton.icon(
                key: const ValueKey('account-entry'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const _AccountDialog(),
                ),
                icon: Icon(
                  account.loggedIn
                      ? Icons.account_circle
                      : Icons.person_outline,
                  size: 20,
                ),
                label: Text(
                  AppMessages.text(
                    context,
                    account.loggedIn ? '我的账号' : '注册 / 登录',
                  ),
                ),
              ),
      ),
    ],
  );
}

class _AccountDialog extends StatefulWidget {
  const _AccountDialog();
  @override
  State<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<_AccountDialog> {
  final account = AccountService.instance;
  final email = TextEditingController();
  final code = TextEditingController();
  Map<String, dynamic>? configuration;
  bool busy = false, biometricAvailable = false;
  String? message;
  Uri? authorization;
  Timer? timer;
  int resend = 0;
  String t(String text) => AppMessages.text(context, text);

  @override
  void initState() {
    super.initState();
    account.addListener(changed);
    unawaited(load());
  }

  Future<void> load() async {
    try {
      await account.initialize();
      if (account.loggedIn) await account.refresh();
      final c = await account.request('config');
      final available = await account.canUseBiometrics();
      if (mounted) {
        setState(() {
          configuration = c;
          biometricAvailable = available;
        });
      }
    } catch (_) {
      if (mounted) setState(() => message = t('账号服务暂时不可用'));
    }
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    account.removeListener(changed);
    account.cancelSignIn();
    timer?.cancel();
    email.dispose();
    code.dispose();
    super.dispose();
  }

  String errorText(Object error) {
    if (error is AccountException) {
      return t(switch (error.code) {
        'invalid_email' => '请输入有效邮箱',
        'invalid_or_expired_code' => '验证码错误或已过期',
        'rate_limited' => '操作频繁，请稍后重试',
        'account_disabled' => '账号已被禁用',
        'biometric_unavailable' => '请先在系统设置中录入生物信息',
        'biometric_cancelled' => '已取消生物验证',
        'login_expired' => '登录已过期，请重试',
        'login_cancelled' => '已取消登录',
        'recent_login_required' => '请重新登录后再删除账号',
        'login_required' => '请先登录',
        'email_delivery_failed' => '邮件发送失败，请稍后重试',
        'email_unconfigured' || 'provider_unconfigured' => '此登录方式尚未配置',
        _ => '账号服务暂时不可用',
      });
    }
    return t('账号服务暂时不可用');
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => message = errorText(e));
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          authorization = null;
        });
      }
    }
  }

  Future<void> send() async {
    if (!email.text.contains('@')) {
      setState(() => message = t('请输入有效邮箱'));
      return;
    }
    await run(() async {
      await account.sendCode(email.text);
      if (!mounted) return;
      setState(() {
        resend = 60;
        message = t('验证码已发送，十分钟内有效');
      });
      timer?.cancel();
      timer = Timer.periodic(const Duration(seconds: 1), (tick) {
        if (!mounted) {
          tick.cancel();
          return;
        }
        setState(() => resend--);
        if (resend <= 0) tick.cancel();
      });
    });
  }

  Future<void> signInProvider(String provider) => account.signInProvider(
    provider,
    openBrowser: !PlatformInfo.isTV,
    onAuthorization: (uri) {
      if (mounted) setState(() => authorization = uri);
    },
  );

  Future<void> removeAccount() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t('删除账号')),
        content: Text(t('删除账号及登录信息，此操作无法撤销。设备上的播放源会保留。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t('删除账号')),
          ),
        ],
      ),
    );
    if (yes == true) await run(account.deleteAccount);
  }

  @override
  Widget build(BuildContext context) {
    final loggedIn = account.loggedIn;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t(loggedIn ? '我的账号' : '注册 / 登录'),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: t('关闭'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (loggedIn) ...[
                Text(
                  account.user!['email'] as String,
                  key: const ValueKey('account-email'),
                ),
                const SizedBox(height: 8),
                Text(t(account.user!['verified'] == true ? '邮箱已验证' : '邮箱未验证')),
                if (account.supportsBiometrics)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t('生物验证解锁账号')),
                    subtitle: Text(
                      t(
                        biometricAvailable
                            ? '支持 Face ID、Touch ID 或设备指纹与人脸验证'
                            : '请先在系统设置中录入生物信息',
                      ),
                    ),
                    value: account.biometric,
                    onChanged: busy || !biometricAvailable
                        ? null
                        : (value) => run(
                            () => account.setBiometric(
                              value,
                              t('验证身份以访问 BobTV 账号'),
                            ),
                          ),
                  ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: busy ? null : () => run(account.logout),
                  child: Text(t('退出登录')),
                ),
                TextButton(
                  onPressed: busy ? null : removeAccount,
                  child: Text(t('删除账号')),
                ),
              ] else if (account.locked) ...[
                Text(t('账号已锁定，播放功能可继续使用')),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => run(() => account.unlock(t('验证身份以访问 BobTV 账号'))),
                  icon: const Icon(Icons.fingerprint),
                  label: Text(t('解锁账号')),
                ),
                TextButton(
                  onPressed: busy ? null : () => run(account.clearLocal),
                  child: Text(t('使用其他方式重新登录')),
                ),
              ] else ...[
                Text(t('注册登录为可选，当前播放功能无需登录')),
                const SizedBox(height: 16),
                if (configuration == null) const LinearProgressIndicator(),
                TextField(
                  controller: email,
                  enabled: !busy,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  maxLength: 254,
                  decoration: InputDecoration(
                    labelText: t('邮箱'),
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: code,
                        enabled: !busy,
                        keyboardType: TextInputType.number,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(6),
                        ],
                        decoration: InputDecoration(labelText: t('验证码')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton(
                      onPressed:
                          busy || resend > 0 || configuration?['email'] != true
                          ? null
                          : send,
                      child: Text(resend > 0 ? '${resend}s' : t('发送验证码')),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: busy || configuration?['email'] != true
                      ? null
                      : () => run(() async {
                          if (code.text.length != 6) {
                            throw const AccountException(
                              'invalid_or_expired_code',
                            );
                          }
                          await account.signInEmail(email.text, code.text);
                          code.clear();
                        }),
                  child: Text(t('验证并登录 / 注册')),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: busy || configuration?['google'] != true
                      ? null
                      : () => run(() => signInProvider('google')),
                  child: Text(t('使用 Google 登录')),
                ),
                OutlinedButton(
                  onPressed: busy || configuration?['apple'] != true
                      ? null
                      : () => run(() => signInProvider('apple')),
                  style: OutlinedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                  ),
                  child: Text(t('使用 Apple 登录')),
                ),
                if (configuration != null &&
                    (configuration!['email'] != true ||
                        configuration!['google'] != true ||
                        configuration!['apple'] != true))
                  Text(
                    t('灰色登录方式尚未配置'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse('https://bobtv.briconbric.com/privacy#accounts'),
                  mode: LaunchMode.externalApplication,
                ),
                child: Text(t('账号隐私说明')),
              ),
              if (busy && authorization != null) ...[
                const SizedBox(height: 12),
                Text(t('扫码登录此设备，请勿分享登录二维码')),
                Center(
                  child: QrImageView(
                    data: authorization.toString(),
                    size: 230,
                    backgroundColor: Colors.white,
                  ),
                ),
              ],
              if (busy) ...[
                const SizedBox(height: 14),
                const LinearProgressIndicator(),
                TextButton(
                  onPressed: () {
                    account.cancelSignIn();
                    setState(() {
                      busy = false;
                      authorization = null;
                    });
                  },
                  child: Text(t('取消')),
                ),
              ],
              if (message != null) ...[
                const SizedBox(height: 12),
                Semantics(liveRegion: true, child: Text(message!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
