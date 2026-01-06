# Research: Gemini PKCE Multibyte Error

## Problem
Calling `benedict-provider-gemini-login` fails with `(error "Multibyte character in data for base64 encoding")`.

## Root Cause Analysis
The function `benedict-provider-gemini--generate-verifier` generates 32 random bytes and then:
1. Concatentates them into a string.
2. Calls `(decode-coding-string ... 'utf-8)`.
3. Calls `(base64url-encode-string ... t)`.

If the random bytes (values 0-255) contain sequences that `decode-coding-string` interprets as valid UTF-8 multibyte characters, the resulting string becomes a **multibyte string**. `base64-encode-string` (called by `base64url-encode-string`) throws an error when it encounters multibyte characters in its input.

## Why Tests Passed
The existing unit test `benedict-provider-gemini-generate-verifier-base64url` mocked `random` to return a sequence of `0..31`.
These are all < 128, which means they are always single-byte ASCII. `decode-coding-string` never produced multibyte characters for this specific input range, so the error was never triggered in CI/tests.

## References
- `benedict-provider-gemini.el:621`
- `test/benedict-provider-gemini-test.el:16`
