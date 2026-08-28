#!/usr/bin/env python3
"""Run a small browser smoke test against a built Pragtical web distribution."""

from __future__ import annotations

import sys

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import sync_playwright


def wait_for_editor(page) -> None:
    page.wait_for_function(
        """() => {
          const canvas = document.querySelector('#canvas');
          const loading = document.querySelector('#loading');
          const close = document.querySelector('#close');
          if (!canvas || canvas.width === 0 || !loading
              || !close || getComputedStyle(loading).display !== 'none'
              || getComputedStyle(close).display !== 'none'
              || document.body.innerText.includes('could not start')) return false;
          const context = canvas.getContext('2d');
          return context && context.getImageData(0, 0, 1, 1).data[3] !== 0;
        }""",
        timeout=60_000,
    )


def main() -> int:
    url = sys.argv[1] if len(sys.argv) > 1 else 'http://127.0.0.1:8000/'
    browser_errors = []

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch()
        page = browser.new_page(viewport={"width": 1280, "height": 800})
        page.on('pageerror', lambda error: browser_errors.append(f'pageerror: {error}'))
        page.on(
            'console',
            lambda message: browser_errors.append(f'console: {message.text}')
            if message.type == 'error' else None,
        )

        try:
            page.goto(url, wait_until='networkidle', timeout=60_000)
            wait_for_editor(page)

            page.locator('#canvas').focus()
            page.keyboard.type('web-smoke')
            page.keyboard.press('Control+S')
            page.wait_for_timeout(250)
            edited_text = page.evaluate(
                "FS.readFile('/home/web_user/welcome.md', {encoding: 'utf8'})"
            )
            if 'web-smoke' not in edited_text:
                raise AssertionError('keyboard input was not saved in the browser filesystem')

            page.reload(wait_until='networkidle', timeout=60_000)
            wait_for_editor(page)
        except PlaywrightTimeoutError as error:
            raise AssertionError(f'web editor did not become ready: {error}') from error
        finally:
            browser.close()

    if browser_errors:
        raise AssertionError('browser reported errors:\n' + '\n'.join(browser_errors))

    print('Web browser smoke test passed.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
