import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/app_config.dart';
import '../../../core/navigation/public_home_navigation.dart';

enum LegalPolicyType { terms, privacy }

class LegalPolicyScreen extends StatelessWidget {
  const LegalPolicyScreen({super.key, required this.type});

  final LegalPolicyType type;

  @override
  Widget build(BuildContext context) {
    final policy = type == LegalPolicyType.terms
        ? _termsPolicy
        : _privacyPolicy;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(policy.title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {
            if (Navigator.of(context).canPop()) {
              context.pop();
            } else {
              openPublicHome(context);
            }
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 42),
              children: [
                Text(
                  policy.title,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    height: 1.08,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Effective date: June 1, 2026',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 22),
                for (final section in policy.sections) ...[
                  Text(
                    section.heading,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final paragraph in section.paragraphs) ...[
                    Text(
                      paragraph,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        height: 1.55,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const SizedBox(height: 8),
                ],
                Text(
                  '(c) 2026 Talkflix. All rights reserved.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LegalPolicy {
  const _LegalPolicy({required this.title, required this.sections});

  final String title;
  final List<_LegalSection> sections;
}

class _LegalSection {
  const _LegalSection({required this.heading, required this.paragraphs});

  final String heading;
  final List<String> paragraphs;
}

const _termsPolicy = _LegalPolicy(
  title: 'Terms of Service',
  sections: [
    _LegalSection(
      heading: '1. About Talkflix',
      paragraphs: [
        'Talkflix provides language practice, social communication, live rooms, video content, subtitles, messaging, tutor discovery, paid language partner discovery, and private coaching related services. These Terms apply when you access Talkflix through the website, mobile apps, shared links, or related services.',
        'By using Talkflix, you agree to these Terms. If you do not agree, do not use the service.',
      ],
    ),
    _LegalSection(
      heading: '2. Eligibility and accounts',
      paragraphs: [
        'You must be old enough to use online social and communication services in your country. Talkflix is not directed to children under 13. If local law requires a higher age or parental consent, you are responsible for meeting that requirement.',
        'You are responsible for the accuracy of your account information, the security of your login credentials, and activity that happens through your account. You must not impersonate another person or create an account for deceptive, abusive, or illegal purposes.',
      ],
    ),
    _LegalSection(
      heading: '3. Community conduct',
      paragraphs: [
        'Talkflix is built for language learning and respectful communication. You must not harass, threaten, exploit, scam, spam, dox, sexually exploit, or discriminate against other users. You must not upload or share illegal content, content that violates another person\'s rights, or content designed to harm the service.',
        'Language practice may involve live audio, video, subtitles, comments, messages, and profile interactions. Use those features responsibly and report unsafe or abusive behavior when you see it.',
      ],
    ),
    _LegalSection(
      heading: '4. Content and licenses',
      paragraphs: [
        'You own the content you create or upload, subject to any rights held by others. You give Talkflix a worldwide, non-exclusive license to host, store, copy, display, translate, subtitle, transmit, and distribute your content as needed to operate, improve, protect, and promote the service.',
        'You must have the rights needed to upload or share content on Talkflix. We may remove content, restrict distribution, or suspend accounts when content appears to violate these Terms, law, platform rules, or community safety expectations.',
      ],
    ),
    _LegalSection(
      heading: '5. Tutors, partners, coaching, and paid services',
      paragraphs: [
        'Talkflix may help users discover language tutors, paid language partners, or private coaching services. Unless Talkflix expressly states otherwise in a separate written agreement, independent tutors, partners, or coaches are responsible for their own profiles, qualifications, schedules, pricing, sessions, taxes, and local compliance.',
        'Paid features may be subject to additional terms shown at purchase. Prices, availability, refunds, subscriptions, taxes, and payment processing may vary by location and payment provider.',
      ],
    ),
    _LegalSection(
      heading: '6. Safety, moderation, and enforcement',
      paragraphs: [
        'We may review reports, use automated or manual safety tools, restrict features, remove content, suspend accounts, or preserve information when reasonably necessary to protect users, comply with law, enforce these Terms, or maintain service integrity.',
        'We do not guarantee that every user, tutor, partner, coach, post, subtitle, translation, comment, or message will be accurate, safe, available, or suitable for your goals.',
      ],
    ),
    _LegalSection(
      heading: '7. Service changes and availability',
      paragraphs: [
        'Talkflix may change, pause, remove, or add features at any time. Some services may be experimental, unavailable in certain regions, or dependent on third-party platforms, networks, app stores, payment providers, or hosting services.',
        'We provide the service on an as-is and as-available basis to the fullest extent allowed by law.',
      ],
    ),
    _LegalSection(
      heading: '8. Limitation of liability',
      paragraphs: [
        'To the fullest extent allowed by law, Talkflix is not liable for indirect, incidental, special, consequential, exemplary, or punitive damages, or for loss of profits, data, goodwill, or opportunities. Nothing in these Terms limits rights that cannot be limited under applicable law.',
      ],
    ),
    _LegalSection(
      heading: '9. Changes to these Terms',
      paragraphs: [
        'We may update these Terms when the service, law, or business needs change. If changes are material, we will take reasonable steps to notify users. Continued use after an update means you accept the updated Terms.',
      ],
    ),
    _LegalSection(
      heading: '10. Contact',
      paragraphs: [
        'Questions about these Terms can be sent to ${AppConfig.supportEmail}.',
      ],
    ),
  ],
);

const _privacyPolicy = _LegalPolicy(
  title: 'Privacy Policy',
  sections: [
    _LegalSection(
      heading: '1. Overview',
      paragraphs: [
        'This Privacy Policy explains how Talkflix collects, uses, shares, stores, and protects information when you use our website, apps, shared links, language practice features, messaging, live rooms, subtitles, tutor discovery, paid partner discovery, and coaching related services.',
        'Privacy laws vary by location. Where a local law gives you additional rights, Talkflix will honor those rights as required.',
      ],
    ),
    _LegalSection(
      heading: '2. Information we collect',
      paragraphs: [
        'We may collect account information such as name, username, email address, phone number if provided, profile photo, country, language preferences, relationship status if you choose to add it, account settings, and authentication details.',
        'We may collect content and communication information such as posts, videos, audio, live room activity, comments, likes, shares, subtitles, translations, messages, reports, tutor or coaching requests, and other information you submit or generate while using Talkflix.',
        'We may collect technical information such as device type, browser, app version, IP address, approximate location inferred from network information, identifiers, logs, diagnostics, crash data, security events, and usage activity.',
      ],
    ),
    _LegalSection(
      heading: '3. How we use information',
      paragraphs: [
        'We use information to create and secure accounts, operate app features, show profiles and content, provide subtitles and translations, support messaging and live communication, process requests, improve reliability, personalize settings, provide customer support, and enforce safety rules.',
        'We may use information to detect abuse, spam, fraud, unauthorized access, policy violations, and behavior that could harm users or the service.',
      ],
    ),
    _LegalSection(
      heading: '4. Sharing and disclosure',
      paragraphs: [
        'Your profile information, content, comments, likes, shares, public activity, and live participation may be visible to other users depending on your settings and the feature you use.',
        'We may share information with service providers that help us host the service, deliver notifications, process payments, provide analytics, support communication features, moderate content, or maintain security. We may also disclose information when required by law, to protect rights and safety, or in connection with a business transfer such as a merger, acquisition, financing, or asset sale.',
        'Talkflix does not sell your personal information in the ordinary meaning of selling it for money. If a privacy law treats certain advertising or analytics activity as a sale or sharing, we will provide required choices where applicable.',
      ],
    ),
    _LegalSection(
      heading: '5. International use and transfers',
      paragraphs: [
        'Talkflix is designed for global language practice. Your information may be processed in countries other than where you live. Those countries may have different data protection laws. We use reasonable safeguards for international processing as required by applicable law.',
      ],
    ),
    _LegalSection(
      heading: '6. Your choices and rights',
      paragraphs: [
        'You can update many profile, privacy, language, notification, and account settings inside Talkflix. Depending on your location, you may have rights to access, correct, delete, export, restrict, or object to certain processing of your personal information.',
        'You can request account deletion at ${AppConfig.accountDeletionUrl}. To request access, correction, deletion, or other privacy help, contact ${AppConfig.supportEmail}. We may need to verify your request before acting on it.',
      ],
    ),
    _LegalSection(
      heading: '7. Retention',
      paragraphs: [
        'We keep information for as long as needed to provide Talkflix, comply with law, resolve disputes, enforce agreements, protect safety, maintain backups, and operate legitimate business records. Retention periods can vary based on account status, content type, safety needs, and legal requirements.',
      ],
    ),
    _LegalSection(
      heading: '8. Children and teens',
      paragraphs: [
        'Talkflix is not directed to children under 13 and we do not knowingly collect personal information from children under 13. If you believe a child provided personal information to Talkflix, contact ${AppConfig.supportEmail} so we can review and take appropriate action.',
        'Teen users should use Talkflix with care and follow local age, consent, and safety requirements.',
      ],
    ),
    _LegalSection(
      heading: '9. Security',
      paragraphs: [
        'We use reasonable technical and organizational measures designed to protect information. No online service can guarantee absolute security, so you should use a strong password, protect your account, and report suspicious activity.',
      ],
    ),
    _LegalSection(
      heading: '10. Changes to this Privacy Policy',
      paragraphs: [
        'We may update this Privacy Policy when our service, technology, legal obligations, or business practices change. If changes are material, we will take reasonable steps to notify users.',
      ],
    ),
    _LegalSection(
      heading: '11. Contact',
      paragraphs: [
        'Questions or privacy requests can be sent to ${AppConfig.supportEmail}.',
      ],
    ),
  ],
);
