import { LaunchProps, Toast, getFrontmostApplication, open, showToast } from '@raycast/api';
import { browserCaptureLink, browsers, readBrowserTab } from './browser-capture';
import type { BrowserName } from './browser-capture';
export default async function CaptureBrowserTab({ arguments: args }: LaunchProps<{ arguments: { browser?: string } }>) {
  const toast = await showToast({ style: Toast.Style.Animated, title: 'Reading browser tab…' });
  try {
    let chosen = args.browser;
    if (!chosen || chosen === 'auto') {
      const app = await getFrontmostApplication();
      chosen = Object.entries(browsers).find(([, id]) => id === app.bundleId)?.[0];
      if (!chosen) throw new Error('Choose Safari, Chrome, or Edge in the command argument, or run this command with that browser in front.');
    }
    if (!Object.hasOwn(browsers, chosen)) throw new Error('Unsupported browser.');
    const tab = await readBrowserTab(chosen as BrowserName);
    await open(browserCaptureLink(tab));
    toast.style = Toast.Style.Success; toast.title = 'Review capture in PaperShelf'; toast.message = 'Only the tab title and public URL were read. Confirm import in PaperShelf.';
  } catch (error) {
    toast.style = Toast.Style.Failure; toast.title = 'Could not capture tab';
    toast.message = error instanceof Error ? error.message : 'Allow Raycast to control the selected browser in macOS Privacy & Security → Automation, then retry.';
  }
}
