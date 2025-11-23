
# Project Blueprint

## Overview

This project is a desktop application built with Flutter, intended to run on macOS, Windows, and Linux. The initial setup focuses on creating a clean, desktop-only foundation by removing mobile-specific configurations and providing a basic windowed application structure.

## Style, Design, and Features

### Initial Setup (Desktop Focus)

*   **Platform:** Desktop-only (macOS, Windows, Linux).
*   **Dependencies:**
    *   Removed `cupertino_icons` as it is specific to iOS.
*   **File Structure:**
    *   Removed `android`, `ios`, and `web` directories and their content.
    *   Removed the default widget test file (`test/widget_test.dart`).
*   **UI:**
    *   A simple `MaterialApp` with a `Scaffold` displaying a centered "Hello Desktop!" message.
    *   The main application window has a title "Flutter Desktop App".

## Current Plan

*   **Task:** Implement a login screen with Firebase Authentication.
*   **Style:** Minimalistic gray-white-black theme.
*   **Features:**
    *   Email/Password authentication.
    *   Google Sign-In.
    *   Facebook Sign-In.
    *   Navigate to a welcome screen on successful login.
    *   Display errors on failed login.
*   **Steps:**
    1.  Update `pubspec.yaml` with the necessary Firebase and routing dependencies (`firebase_core`, `firebase_auth`, `google_sign_in`, `flutter_facebook_auth`, `go_router`).
    2.  Run `flutter pub get` to install the new dependencies.
    3.  Create a new `lib/firebase_options.dart` file for Firebase configuration.
    4.  Create a `lib/login_screen.dart` file for the login UI and logic.
    5.  Create a `lib/welcome_screen.dart` for the post-login screen.
    6.  Update `lib/main.dart` to initialize Firebase, set up the theme, and configure the router.
