import { Toast, getPreferenceValues, showToast } from '@raycast/api';
import { checkConnection, connectionPath } from './local-api';
export default async function CheckConnection() {
  const preferences = getPreferenceValues<{ connectionFile?: string }>();
  const toast = await showToast({ style: Toast.Style.Animated, title: 'Checking PaperShelf…' });
  try {
    const result = await checkConnection({ filename: connectionPath(preferences.connectionFile) });
    toast.style = Toast.Style.Success; toast.title = 'Connected to PaperShelf'; toast.message = result.readOnly ? 'Local API is read-only.' : 'Local API is available.';
  } catch (error) { toast.style = Toast.Style.Failure; toast.title = 'Connection failed'; toast.message = error instanceof Error ? error.message : 'Open PaperShelf and enable Local API.'; }
}
