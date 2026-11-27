document.querySelector('form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const token = new FormData(event.currentTarget).get('token').trim();
  const status = document.querySelector('[role=status]');
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(token)) {
    status.textContent = 'Enter the token configured on this kiosk.';
    return;
  }
  await chrome.storage.local.set({pairingToken: token});
  event.target.reset();
  status.textContent = 'Pairing token saved.';
});
