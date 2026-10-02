#!/usr/bin/env node
// Builds the owner guides (HTML -> PDF) with headless Chromium and refuses to
// write a PDF if any command block would overflow its line at A4 print width:
// with `white-space: pre` an overflowing command is clipped, and a clipped
// command pasted into a terminal fails (live install 02.10.2026: a wrapped
// curl line from the PDF came back as 404).
//
// Usage:  node docs/build-guides.mjs [guide.html ...]
// Needs playwright-core and a Chromium. Set PLAYWRIGHT_CORE to the package dir
// if it is not resolvable from here, and CHROMIUM to the browser binary if
// playwright-core cannot find its own.
// After building, run: python3 tests/test_guides_copy_safe.py

import { createRequire } from 'node:module'
import { resolve, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core')

const here = dirname(fileURLToPath(import.meta.url))
const DEFAULT_GUIDES = [
  resolve(here, 'install-guide/install-guide.html'),
  resolve(here, 'restore-guide/restore-guide.html'),
]
// A4 (210mm) minus 15mm side margins from @page = 180mm = 680 CSS px at 96 dpi.
const CONTENT_WIDTH_PX = 680

const guides = process.argv.length > 2 ? process.argv.slice(2).map((p) => resolve(p)) : DEFAULT_GUIDES
const browser = await chromium.launch(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {})
let failed = false
try {
  for (const html of guides) {
    const page = await browser.newPage({ viewport: { width: CONTENT_WIDTH_PX, height: 1000 } })
    await page.goto(pathToFileURL(html).href, { waitUntil: 'networkidle' })
    await page.emulateMedia({ media: 'print' })
    await page.evaluate(() => document.fonts.ready)
    const overflow = await page.$$eval('pre.cmd', (blocks) =>
      blocks
        .filter((b) => b.scrollWidth > b.clientWidth + 1)
        .map((b) => `${b.textContent} (${b.scrollWidth} > ${b.clientWidth}px)`),
    )
    if (overflow.length > 0) {
      failed = true
      console.error(`FAIL ${html}: command blocks wider than the page:`)
      for (const line of overflow) console.error(`  ${line}`)
      await page.close()
      continue
    }
    const pdf = html.replace(/\.html$/, '.pdf')
    await page.pdf({ path: pdf, preferCSSPageSize: true, printBackground: true })
    const count = await page.$$eval('pre.cmd', (b) => b.length)
    console.log(`OK ${pdf} (${count} command blocks, none overflow)`)
    await page.close()
  }
} finally {
  await browser.close()
}
process.exit(failed ? 1 : 0)
