# PB Intercom for iOS

An iOS app that receives audio and video calls from SIP door stations. A call
can wake a locked phone through a VoIP push, the phone rings through CallKit,
and during the call the app can send DTMF to open the door.

- SIP and media: [PJSIP](https://www.pjsip.org), built from source. H.264
  video uses VideoToolbox.
- Sign-in: OpenID Connect against Keycloak, through
  [AppAuth](https://github.com/openid/AppAuth-iOS). One app serves several
  tenants, each with its own realm.
- Calls: PushKit and CallKit.

The app needs a backend that this repository doesn't include. See
[Server](#server).

## Requirements

- Xcode 26.5 or later
- iOS 18.0 or later on the device
- An Apple Developer account, for push notifications and to install on a device

## Building

1. **Build PJSIP.** This downloads pjproject at a pinned commit, applies the
   patches in `pjsip-patches/` and writes `Vendor/PJSIP.xcframework`
   (device and simulator). It takes a few minutes and is only needed again
   when the pinned commit or the patches change.

   ```sh
   scripts/build-pjsip-ios.sh
   ```

2. **Set your own identifiers.** Copy the example and fill it in:

   ```sh
   cp Config/Private.example.xcconfig Config/Private.xcconfig
   ```

   | Setting | What it is |
   |---|---|
   | `PB_SERVER_HOST` | Host of your backend, without scheme or path |
   | `DEVELOPMENT_TEAM` | Your Apple Developer team ID |
   | `PRODUCT_BUNDLE_IDENTIFIER` | An App ID registered to your team, with Push Notifications enabled |

   Without `Private.xcconfig`, the app still builds for the simulator with
   placeholder values, but it can't reach a server.

3. **Open `sipclient.xcodeproj`** in Xcode and run the `sipclient` scheme.

## Server

The app talks to one host (`PB_SERVER_HOST`) over HTTPS:

| Route | Purpose |
|---|---|
| `GET /app/v1/tenants` | The tenants shown at login: `key`, `displayName` and Keycloak `issuer`. No token. |
| `GET /app/v1/tenants/{key}` | One tenant, for an invite link `intercom://tenant/{key}`. No token. |
| `GET /app/v1/me` | Whether the user is linked to a SIP extension, and its credentials (`username`, `password`, `domain`, `registrar`, `port`, `transport`). |
| `PUT /app/v1/devices/{id}` | Registers the phone's VoIP push token (`platform`, `pushToken`, `apnsEnvironment`). |
| `DELETE /app/v1/devices/{id}` | Removes it at logout. |
| `POST /wake/v1/calls/{uuid}/status` | Reports whether a woken phone is still `waiting` or has `declined`. Authorised with the `callToken` from the push. |

The `/app/v1/` routes take the user's Keycloak access token. The user's
identity comes only from that token.

A wake is a VoIP push to the topic `<bundle id>.voip` with this payload:

```json
{ "aps": {}, "uuid": "<call UUID>", "caller": "Front door", "sentAt": 1767225600000, "callToken": "<token>" }
```

`sentAt` is in milliseconds. `scripts/send-voip-push` sends one by hand for
testing; run it without arguments to see its flags.

### Keycloak

In each tenant's realm, create a public client `sipclient-ios` with:

- Redirect URI `<bundle id>://oauth/callback`
- Scopes `openid`, `profile`, `email` and `offline_access`, so the app stays
  signed in, and "Revoke Refresh Token" off, so a refresh token isn't single
  use
- An audience mapper for your backend's client, if the backend checks the
  token's audience
- Optionally, a realm or client role `sipclient-debug`, which shows a DTMF
  keypad in place of the Open door button during a call

## Licence

Copyright © 2026 Performance Buildings AG

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 2 of the License, or (at your option) any later
version. See [LICENSE](LICENSE).

PJSIP is GPL v2 or later as well. The other bundled libraries (AppAuth,
Speex, GSM 06.10, iLBC, WebRTC and libyuv) are under their own permissive
licences; their texts are in `sipclient/Licenses/` and shown in the app under
Acknowledgements. The changes this repository makes to PJSIP are in
`pjsip-patches/`.
