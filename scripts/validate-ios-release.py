#!/usr/bin/env python3
"""Fail before signing, and verify the actual archived app without printing keys."""
import argparse
import os
from pathlib import Path
import plistlib
from urllib.parse import urlparse


def validate(values):
    for key in ('SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY', 'SUPABASE_AUTH_REDIRECT_URL', 'GIDClientID'):
        value = values.get(key, '')
        if not isinstance(value, str) or not value.strip() or '$(' in value or '${' in value:
            raise ValueError(f'{key} is missing or unresolved')
    url = urlparse(values['SUPABASE_URL'])
    if url.scheme != 'https' or url.hostname != 'zeuivahkowbxmfzsnagt.supabase.co' or url.username:
        raise ValueError('Release must use the reviewed production Supabase project')
    if not values['SUPABASE_PUBLISHABLE_KEY'].startswith('sb_publishable_'):
        raise ValueError('Release requires a public client key, never a privileged key')
    if values['SUPABASE_AUTH_REDIRECT_URL'] != 'cheeseapp://auth/callback':
        raise ValueError('OAuth redirect does not match the app URL scheme')
    if values.get('CheesePushEnvironment') != 'production':
        raise ValueError('Release APNs environment must be production')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-settings', action='store_true')
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    if args.build_settings:
        values = dict(os.environ)
        values['GIDClientID'] = values.get('GOOGLE_IOS_CLIENT_ID', '')
        values['CheesePushEnvironment'] = values.get('APS_ENVIRONMENT', '')
    elif args.app:
        values = plistlib.loads((args.app / 'Info.plist').read_bytes())
        manifest = plistlib.loads((args.app / 'PrivacyInfo.xcprivacy').read_bytes())
        defaults = [entry for entry in manifest.get('NSPrivacyAccessedAPITypes', [])
                    if entry.get('NSPrivacyAccessedAPIType') == 'NSPrivacyAccessedAPICategoryUserDefaults']
        if not defaults or 'CA92.1' not in defaults[0].get('NSPrivacyAccessedAPITypeReasons', []):
            raise ValueError('App-owned UserDefaults declaration missing from archive')
        if manifest.get('NSPrivacyTracking') is not False:
            raise ValueError('Unexpected tracking declaration')
    else:
        parser.error('provide --build-settings or --app PATH')
    validate(values)
    print('PASS: production configuration' + (' and bundled privacy manifest' if args.app else ''))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        raise SystemExit(f'error: Release validation failed: {error}')
