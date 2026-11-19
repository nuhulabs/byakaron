# Privacy Policy: Byakaron Keyboard

How the Android keyboard handles information on your device, written for Google Play submission and for anyone who wants a clear account of what the App does with keystrokes.

- **Effective:** 27 September 2026
- **Last modified:** 19 November 2026
- **Developer:** NuhuLabs

## 1. Scope

This Privacy Policy explains how Byakaron Keyboard (the "App") handles information on Android devices.

- **Application:** Byakaron Keyboard
- **Package name:** com.byakaron
- **Developer:** NuhuLabs
- **Platform:** Android (minimum Android 5.0 / API 21)
- **Languages:** Bengali (phonetic and fixed layouts) and English

The App is a third-party input method (keyboard). Because a keyboard processes everything you type, we treat the handling of your keystrokes as the central privacy concern for this App. This policy is written to be specific about that.

## 2. Our Privacy Promise

Byakaron Keyboard is fully offline. It does not request the Android INTERNET permission, which means it is technically incapable of transmitting your data to us or to anyone else.

- The App contains no advertising, no analytics, no crash-reporting, and no telemetry SDKs.
- The App contains no web view, no HTTP client, and no network code path.
- The App requests no advertising ID, device ID, IMEI, or subscriber identifier.
- We operate no servers, and we have no user accounts. There is no backend to send your data to.
- We do not sell, rent, trade, or share your personal information with anyone. We do not have anyone to share it with.
- Everything the App does with your typing happens locally on your device, between the App and the app you are typing into.

## 3. Data We Do Not Collect

For clarity, the App does not collect, transmit, upload, log to a remote server, or otherwise disclose any of the following:

- Keystrokes, typed text, or words you compose
- The contents of any app you type in, including the app's identity beyond what is described in Keystroke Processing
- Clipboard contents, except as stored locally and as you explicitly choose to export
- Contact names, except as read locally when you opt in
- Files, photos, media, location, camera, microphone, or device sensors
- Account credentials, email addresses, or phone numbers
- Advertising identifiers or cross-app tracking identifiers
- Diagnostic or crash reports (the App has no crash-reporting service)
- Your IP address, because the App has no network access

If you ever find that the App is transmitting any of the above, that would be a bug, and we would treat it as a security issue. Please report it using the details in Contact.

## 4. Data Stored on Your Device Only

The App stores settings and preferences locally in Android's private app storage, and uses a small on-device database for learned-word history. None of this data is transmitted off your device by the App.

You can erase it at any time by clearing the App's data in Android Settings, or by uninstalling the App.

## 5. Keystroke Processing on Your Device Only

To produce suggestions and autocorrect text, the App processes the words you type in memory on your device.

- The App is a standard Android input method. Text you type is delivered to the App by Android itself, and suggestions are returned the same way, through the Android input connection.
- This processing is a local, in-memory operation, the same mechanism that makes any on-device keyboard's autocorrect work.
- Because the App has no INTERNET permission, processed text cannot be transmitted by the App.
- The App does not inspect, log, or retain the contents of text inside other apps beyond what the active input field requires.

### Incognito Mode

If you need extra assurance for a particular field, the App offers incognito behaviour:

- **Incognito toolbar key:** toggled from the keyboard toolbar, and disables suggestion and toolbar behaviour for the current field.
- **Force incognito mode:** a persistent setting in Settings → Advanced that applies incognito behaviour everywhere until you turn it off.

While incognito is active, the App does not record recent-key history or learn from what you type.

### Learn from Typing / Personal Dictionary

The App can learn words you use so they appear in your personal dictionary. This learning happens only on your device, is off by default, and can be turned off in the App's settings. When disabled, nothing is learned or stored.

## 6. Clipboard History

The App can maintain a local history of the clipboard so you can paste recent items from the keyboard toolbar. This is a local-only feature.

- **Default state:** enabled.
- **Retention:** clipboard history entries expire automatically. The default retention period is short (10 minutes) and is configurable in the App's settings.
- **Storage:** entries are kept in the App's private storage, not transmitted.
- **Pinning:** items you explicitly pin are retained until you unpin or delete them.
- **Large content:** if you copy large text or files, the App may store them locally so it can paste them back; there is a configurable size limit.

You can clear the entire clipboard history, or disable the feature, from the App's settings at any time.

## 7. Contact Names

To improve suggestions, the App has an optional feature that lets it suggest contact names.

- **Default state:** off. It does not read your contacts unless you turn it on.
- **What is read:** contact display names only. Byakaron does not read phone numbers, email addresses, or any other contact fields, and does not read message content.
- **How it is used:** names are stored locally in the App's private storage and used only to build on-device suggestions.
- **Retention / removal:** the names are held in the App's local database and refreshed from your contacts as they change. Clearing the App's data or uninstalling removes them.

If you do not enable this feature, the App does not access your contacts at all.

## 8. Data You Choose to Export

Two features let you move your data out of the App, but only when you explicitly ask for it, and only to a location you choose. The App never sends this data anywhere by itself.

### Backup and Restore

Settings → Advanced → Backup and Restore creates an archive containing your App settings, layouts, and learned word / history data. You choose where the archive is saved using Android's standard file picker.

- The archive is written only to the destination you select.
- The App has no network access, so it cannot upload the archive.
- Anyone with access to the saved file can read it, so treat it as a private copy of your data.
- Restoring reads an archive that you select, and only when you confirm.

### Save Log (diagnostics)

Settings → About → Save log writes a plain-text diagnostics file containing the App's internal log and the device's system log. You choose where it is saved.

- This file is generated locally and saved locally.
- It is never automatically uploaded.
- It may contain technical diagnostic detail about the App and the device. Review it before sharing it with anyone.

## 9. Gesture Typing Data Collection

This section describes a data-collection feature that is present in the codebase but unavailable in the current Byakaron build, so the situation is documented accurately rather than omitted.

In current Byakaron Keyboard builds, this feature is inactive. The gesture-typing library it depends on is not bundled, and the related settings are displayed as permanently disabled. You cannot enable it, no gesture data is recorded, and no gesture data is shared.

For completeness, the feature is designed to work as follows should it ever become active:

- **It is opt-in.** It never runs unless you deliberately enable it in Settings → Gesture typing, after reading an on-screen explanation of what would be collected.
- **Active collection mode** shows you a specific target word, which you type with a swipe gesture. The words involved are drawn from public word lists.
- **Background collection mode,** if offered, would let you contribute samples from your ordinary typing in other apps. This mode would be off by default, configurable, and would clearly indicate when collection is active.
- **A review screen** would show you the data before anything is submitted, so you can confirm or cancel.
- **You export the data yourself.** The App would produce a data file and hand it to you through Android's share sheet. The App itself has no network access and would not upload it. Where a user chooses to send such a file, that destination is selected by the user, not by us.
- **Deletion and anonymity:** a review screen in the design lets you delete individual entries and clear the collected data. Contributors are credited collectively rather than by name.

Because the feature is inactive, no gesture data is collected, stored, or shared in the version of this App you are using. If this ever changes, we will update this section and the Play Console Data safety form before shipping a build in which the feature is active.

## 10. Android Backup

The App declares Android's standard backup support. This means that, if you have Android's system backup (for example, Google Backup) enabled, Android may back up the App's own settings and preference files to your Google account, and restore them on another device you own.

- This backup is handled entirely by Android and your Google account, under Google's own privacy terms, not by us.
- It applies to App settings and preferences only.
- Keystrokes, clipboard history, and learned-word history are not part of the App's backed-up preference state.
- You can disable this at any time in your device's Android backup settings.

## 11. Permissions

The App requests only the following permissions, all of which support local features. None of them is used off the device.

- **VIBRATE:** haptic feedback when you press a key or a suggestion.
- **RECEIVE_BOOT_COMPLETED:** reload your language and layout setup after the device restarts.
- **READ_USER_DICTIONARY:** read a personal user dictionary you have chosen to add, for better suggestions.
- **WRITE_USER_DICTIONARY:** save words you add to your personal user dictionary.
- **READ_CONTACTS:** optional, off by default. Lets the App suggest contact names locally. See Contact Names.

Also:

- The App does not request INTERNET, ACCESS_NETWORK_STATE, storage, camera, microphone, location, or phone-state permissions.
- READ_CONTACTS is only accessed if you turn on contact suggestions. If you decline or later disable the feature, contacts are not read.
- READ_USER_DICTIONARY / WRITE_USER_DICTIONARY only operate on the Android user dictionary facility. Dictionary text stays on your device.

## 12. Advertising and Tracking

The App contains no advertising. It does not:

- display ads or sponsored content;
- use Google Play Services, Firebase, or any advertising SDK;
- request or read the Android advertising ID;
- perform cross-app or cross-site tracking;
- build a profile of you for any purpose.

There is no data for us to monetise, and no incentive for us to collect any.

## 13. Children

Byakaron Keyboard is a general-purpose utility and is not directed at children. It does not knowingly collect personal information from anyone, including children, because it does not collect personal information from anyone at all.

The App stores everything locally on your device. If a child uses the App on a device you control, the local data is covered by the same controls described in Your Rights and Data Deletion.

Because the App holds no server-side copy of any data, there is no child data held by us to access, correct, or delete.

## 14. Security

We take the privacy of your data seriously, which in this App's case mostly means keeping the data on your device:

- The App has no network access, so there is no risk of the App exfiltrating your data to a remote server.
- App data is stored in Android's private app storage, which is isolated from other apps by the Android sandbox.
- No data is encrypted in transit, because nothing is transmitted.
- The App is signed and distributed through the Google Play Store.

We cannot guarantee absolute security. Android itself, other apps with elevated permissions, and a compromised or rooted device could all affect local data. Please protect your device with a screen lock and keep the operating system up to date.

## 15. Your Rights and Data Deletion

Depending on where you live, you may have rights under privacy law to access, correct, delete, or object to the processing of your personal information.

In practice, because the App does not collect your personal information:

- We hold no personal information about you, so there is nothing for us to access, correct, export, or delete on your behalf.
- All App data is on your device, and you control it directly.

To delete everything the App has stored, choose any of the following:

- **Uninstall the App.** This removes the App and all of its local data.
- **Clear the App's data.** Go to Android Settings → Apps → Byakaron Keyboard → Storage → Clear storage.
- **Within the App:** clear clipboard history, or disable clipboard history; delete learned words from your personal dictionary; disable contact-name suggestions, which removes stored contact names; delete an exported backup archive from wherever you saved it.

Because no copy of your data is held on our side, deleting the local data is a complete deletion. There is no separate server-side deletion to request.

If you have a question about this policy or believe your rights have not been respected, contact us using the details in Contact and we will respond as promptly as we can.

## 16. Changes to This Policy

We may update this Privacy Policy from time to time, for example if the App gains a new feature, or if the contact information below changes.

- The "Last modified" date at the top of this page always reflects the current version.
- If a change materially affects how your information is handled, we will describe the change prominently on this page.
- Significant changes will be reflected in the Play Console listing and in the App's store description.
- Continuing to use the App after a change takes effect means the updated policy applies to it.

Because the App is fully offline, a policy change is not something that can affect data already stored on your device without your involvement.

## 17. Contact

If you have any questions, concerns, or requests regarding this Privacy Policy or the Byakaron Keyboard App, please contact us:

- **Developer:** NuhuLabs
- **Email:** hello@nuhulabs.com
- **This policy:** https://byakaron.com/policy
- **Website:** https://byakaron.com

Please include your device model, Android version, and the App version (found in Settings → About) if you are reporting a problem, along with a clear description of what you observed. This helps us investigate effectively.

We will respond to privacy-related enquiries as promptly as we reasonably can.

## Appendix A: Google Play Data Safety Summary

This appendix maps the disclosures above to the corresponding answers in the Google Play Console Data safety form, to help keep the listing and this policy consistent.

- **Does your app collect or share any of the required user data types?** No. No INTERNET permission; no SDKs; all processing is local.
- **Is all user data collected by your app encrypted in transit?** N/A. Nothing is transmitted.
- **Do you provide a way for users to request that their data is deleted?** Yes, locally. See Your Rights and Data Deletion.
- **Is the app a keyboard?** Yes. The App is an input method; keyboard apps may be treated as exempt in Data safety, but the disclosures above are still made voluntarily.
- **Data collected:** None. See Data We Do Not Collect.
- **Data shared:** None. See Data We Do Not Collect.
- **Data used for tracking:** No. See Advertising and Tracking.

READ_CONTACTS is declared in the manifest but defaults to off and is only used locally for on-device suggestions. If contact suggestions are ever made reachable in a Play build, the Data safety answers will be re-evaluated before release.
