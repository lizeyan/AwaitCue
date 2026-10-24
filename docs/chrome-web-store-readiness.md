# Chrome Web Store readiness

This document is the submission checklist and reviewer-facing disclosure draft for **AwaitCue for Chromium**.

## Submission status

| Area | Status | Evidence / remaining work |
| --- | --- | --- |
| Manifest V3 | Ready | `manifest_version: 3`, minimum Chrome 116. |
| Single purpose | Ready | The extension binds a user-selected page region to the AwaitCue macOS companion so that the region can be observed for a user-defined Condition. |
| Permission minimization | Ready with disclosure | Removed `activeTab`, `tabs`, `tabCapture`, and `offscreen`; the remaining permissions are exercised by the DOM-only implementation. Broad HTTP/HTTPS host access remains necessary for macOS global selection without a preceding browser click. |
| Remote hosted code | Ready | Store package contains only bundled JS and icons; audit rejects remote scripts, `eval`, `new Function`, source maps, and extra files. |
| Deterministic ZIP | Ready | `npm run package:store` produces `dist/awaitcue-chromium-0.1.0.zip`; repeated packaging is byte-identical. |
| Package icon | Ready | 16, 32, 48, and 128 px PNG icons are included. |
| Privacy disclosure | Ready after merge | `docs/privacy-policy.md` is complete; use the public GitHub HTTPS URL after this change reaches `master`. |
| Store screenshots | Blocked on final product capture | At least one 1280×800 or 640×400 current-product screenshot must be uploaded. |
| Developer account | External blocker | Publisher account, contact email, fee, and 2-Step Verification must be completed in the Chrome Web Store dashboard. |

Chrome requires a narrow, easy-to-understand single purpose, and permissions must be the narrowest necessary for it ([Quality guidelines](https://developer.chrome.com/docs/webstore/program-policies/quality-guidelines), [Program policies](https://developer.chrome.com/docs/webstore/program-policies/policies/)). The July 2026 policy update additionally requires all data collection to be prominently disclosed and strictly necessary for the disclosed purpose; enforcement began August 1, 2026 ([Chrome Web Store policy updates](https://developer.chrome.com/blog/cws-policy-updates-2026)).

## Copy-ready Privacy practices fields

### Single purpose

> AwaitCue for Chromium lets the AwaitCue macOS app bind a user-selected region of a specific Chromium tab and observe that region until the user-defined Condition is satisfied.

Do not describe the extension as a generic automation platform, browsing assistant, AI assistant, or notification suite. Those descriptions make the single purpose look broader than the shipped functionality.

### Permission justifications

| Permission | Reviewer justification |
| --- | --- |
| `nativeMessaging` | Communicates only with the installed AwaitCue macOS companion. It receives explicit bind, unbind, and focus commands and sends the selected region's limited DOM evidence back to that local companion. |
| `scripting` | Injects the packaged `content.js` into the exact tab selected by the user so the extension can map the screen rectangle to the page viewport and observe the selected region. No downloaded code is executed. |
| `storage` | Stores one random extension installation identifier used to distinguish Chrome profiles. It does not store DOM text, URLs, browsing history, Conditions, or model results. |
| `http://*/*`, `https://*/*` | AwaitCue's core interaction starts from a macOS global rectangle selection, not a browser action. Chrome's `activeTab` grant only applies after a browser-recognized user gesture, so it cannot authorize that native-initiated selection. Host access is used only for the exact user-selected tab: read its URL/title, inject the packaged observer, and continue observing the bound region in the background. Restricted Chrome pages are not supported. |

Chrome documents optional permissions and `activeTab` as preferred ways to reduce access when the user flow permits them ([Declare permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions), [Permission warning guidelines](https://developer.chrome.com/docs/extensions/develop/concepts/permission-warnings)). AwaitCue cannot replace broad host access with `activeTab` without changing its confirmed macOS-global-selection interaction: `activeTab` requires a browser action, command, context-menu, or other Chrome-recognized user gesture. This trade-off must be explicit in review notes and the user-facing disclosure.

### Remote code

Select:

> **No, I am not using remote code.**

All executable logic is bundled in the submitted ZIP. The package contains no remote script tags, dynamic code download, `eval`, `new Function`, or source maps. Manifest V3 requires extension functionality to be discernible from submitted code and prohibits executing remotely hosted logic ([Manifest V3 requirements](https://developer.chrome.com/docs/webstore/program-policies/mv3-requirements/), [Remote hosted code guidance](https://developer.chrome.com/docs/extensions/develop/migrate/remote-hosted-code)).

### Data types to disclose

Declare conservatively in the dashboard:

- **Website content:** text, ARIA/semantic attributes, status classes, and element coordinates from the region the user explicitly selects.
- **Web browsing activity / URL information:** URL, host, and title of the exact selected tab. AwaitCue does not enumerate or retain browsing history, but the dashboard category should be selected if its wording includes observed page URLs.
- **Authentication information:** **not collected** by the extension. Cookies, passwords, form submissions, and browser credentials are not accessed through cookie or web-request APIs.
- **Location, financial, health, communications, and personal identifiers:** not intentionally collected as categories; however, a selected region can visibly contain such information. The prominent disclosure must warn users not to select sensitive regions unless their configured model provider is permitted to receive them.

### Data use and transfer

> AwaitCue for Chromium processes only the tab and region the user selects. The extension sends the selected region's limited DOM text, semantic attributes, status classes, coordinates, and URL/title to the AwaitCue macOS companion through Chrome Native Messaging. It never captures browser screenshots or tab video. The extension does not send network requests to an AwaitCue-operated server and does not sell or use data for advertising, credit, profiling, or unrelated analytics. The macOS companion may send the evidence to the model API endpoint configured and confirmed by the user. Data handling and retention by that endpoint are controlled by its provider.

> The extension keeps evidence in memory only while a Hook is active. `chrome.storage.local` contains only a random installation identifier. Unbinding the Hook, closing or replacing the exact tab, or disconnecting the native companion releases the observer.

The Chrome Web Store requires accurate disclosure of collection, use, sharing, and every receiving party; data use must stay limited to the disclosed single purpose and use modern cryptography when transmitted ([Program policies](https://developer.chrome.com/docs/webstore/program-policies/policies/), [Limited Use](https://developer.chrome.com/docs/webstore/program-policies/limited-use)). The dashboard fields and privacy policy must agree ([Privacy practices](https://developer.chrome.com/docs/webstore/cws-dashboard-privacy)).

### Required Limited Use statement

Publish this statement on the AwaitCue website or privacy-policy page:

> The use of information received from Google APIs will adhere to the Chrome Web Store User Data Policy, including the Limited Use requirements.

## Published privacy policy

Use this public URL after the policy reaches `master`:

> https://github.com/lizeyan/AwaitCue/blob/master/docs/privacy-policy.md

The policy source is `docs/privacy-policy.md` and covers the following required points.

## Privacy policy coverage

The public privacy policy should state, in plain language:

1. AwaitCue's single purpose.
2. Exactly what the extension reads: selected-tab URL/title and selected-region DOM/ARIA/status attributes.
3. When collection begins and ends.
4. That the extension sends data only to the local AwaitCue companion through Native Messaging.
5. That the companion sends data only to the API hostname explicitly configured and confirmed by the user.
6. That no AwaitCue-operated telemetry or crash upload is enabled in the current release.
7. That DOM evidence is memory-only and not written to the extension's storage, and that the extension does not capture browser screenshots.
8. How to stop collection: cancel/unbind the Hook, close the bound tab, quit AwaitCue, or remove the extension.
9. How to request deletion of local data and contact the maintainer.
10. The Limited Use statement above.

## Store listing draft

**Name**

> AwaitCue for Chromium

**Short description**

> Bind a selected tab region to AwaitCue and return to it when its Condition is ready.

**Detailed description — required claims only**

> AwaitCue for Chromium connects a specific Chromium tab and the region you select to the AwaitCue macOS app. AwaitCue observes the region's page text and semantic status for the Condition you define, then waits for an appropriate moment before notifying you. The extension does not capture screenshots and does not automatically click, submit, publish, retry, or operate the page for you. Pages whose state exists only in canvas or images may not provide enough semantic evidence for a decision.

Do not claim automatic support for every Chromium browser in the Chrome listing. Chrome Web Store distribution directly covers Chrome; Arc and other Chromium browsers may allow Chrome Web Store installation, while Microsoft Edge Add-ons is a separate distribution channel.

## Listing assets

The current dashboard guidance requires a store icon and at least one screenshot; up to five screenshots can be provided. Screenshots should be current and show the actual user experience ([Complete listing information](https://developer.chrome.com/docs/webstore/cws-dashboard-listing), [Supplying images](https://developer.chrome.com/docs/webstore/images)).

Required before submission:

- [x] 128×128 package/store icon.
- [ ] At least one 1280×800 screenshot (preferred) or 640×400 screenshot.
- [ ] Public privacy policy HTTPS URL.
- [ ] Support/homepage URL.
- [ ] Verified contact email and 2-Step Verification.
- [ ] Store listing localized at least in English; Chinese localization is recommended.

Recommended screenshots:

1. User frames a build-status region in Chrome.
2. AwaitCue confirms the specific tab, selected region, and Condition interpretation.
3. A Hook observes in the background without changing the page.
4. The privacy/host disclosure and explanation that browser screenshots are never captured.
5. Notification returning the user to the exact tab.

## Build, audit, and package

Run from `BrowserExtension/`:

```bash
npm ci
npm run lint
npm run typecheck
npm test
npm run coverage
npm run package:store
```

The store package is written to:

```text
BrowserExtension/dist/awaitcue-chromium-0.1.0.zip
```

Automated checks enforce:

- exact minimum permission list;
- required package icons;
- no source maps;
- no remote scripts or dynamic string execution;
- exact package contents with `manifest.json` at ZIP root;
- deterministic ZIP bytes;
- DOM evidence capped below the native-message budget;
- large-DOM extraction performance;
- unchanged-evidence suppression;
- native-host reconnect;
- exact-tab disappearance reported as Target Unavailable rather than silently rebound.

