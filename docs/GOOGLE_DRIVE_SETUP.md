# Google Drive setup

Keeper uploads to *your* Google Drive using an OAuth client that *you* create. It takes about five minutes, is free, and means no third party ever sits between your photos and Google.

Keeper asks for one permission only: **`drive.file`**. That lets it see and manage files and folders *it created*, and nothing else in your Drive.

## 1. Create a Google Cloud project

1. Open <https://console.cloud.google.com/> and sign in.
2. Click the project picker → **New Project** → name it `Keeper` → **Create**.

## 2. Enable the Drive API

1. **APIs & Services → Library**.
2. Search for **Google Drive API** → **Enable**.

## 3. Configure the consent screen

1. **APIs & Services → OAuth consent screen** (may appear as *Google Auth Platform*).
2. User type **External** → fill in the app name (`Keeper`), your email as support and developer contact.
3. Scopes: add `.../auth/drive.file` (non-sensitive; no Google verification is required).
4. **Audience / Test users:** add your own Google account while the app is in *Testing*.
5. Recommended: **Publish app** (move it to *In production*). Google expires refresh tokens after 7 days for apps left in *Testing*, which would make you sign in again every week. Because `drive.file` is a non-sensitive scope, publishing does not require review.

## 4. Create the OAuth client

1. **APIs & Services → Credentials → Create credentials → OAuth client ID**.
2. Application type: **Desktop app**. Name it `Keeper desktop`.
3. Copy the **Client ID** (and the **Client secret**, which Google shows for desktop clients; Google documents that it isn't confidential for installed apps).

## 5. Connect Keeper

1. Open Keeper → **Settings (⌘,) → Google Drive**.
2. Paste the Client ID (and secret) → **Sign in with Google**.
3. Approve in the browser. You'll see "You're connected" and can close the tab.
4. Back in Keeper: pick photos → **Share → Upload to Google Drive…** (`⌘U`).

The client secret is stored in your macOS Keychain, the client ID in the app's preferences, and sign-in tokens in the Keychain.

## Baking in a default client ID (maintainers)

If you distribute builds and want users to skip steps 1–4, set the client ID at build time:

```bash
KEEPER_GOOGLE_CLIENT_ID=1234-abc.apps.googleusercontent.com ./Scripts/build-app.sh
```

It's written to the app's `Info.plist` as `KeeperGoogleClientID` and used when the user hasn't entered their own. Because the app is open source, treat the client ID as public.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Access blocked: app has not completed verification" | Add your account under **Test users**, or publish the app (step 3.5). |
| `redirect_uri_mismatch` | The OAuth client must be type **Desktop app**, not Web. |
| `invalid_client` | Client ID/secret mismatch. Re-copy both. |
| Asked to sign in again every week | App is still in *Testing*; publish it (step 3.5). |
| HTTP 403 `accessNotConfigured` | Enable the Drive API for the *same* project (step 2). |
| Uploads create a second "Keeper" folder | With `drive.file`, Keeper only sees folders it made. A folder you created by hand in the Drive website won't be found. |
