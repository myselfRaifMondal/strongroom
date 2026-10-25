# Installing Strongroom on Windows

Strongroom is a password manager. It keeps your passwords in one locked file
(your "vault") on your own computer. Nothing is sent to the internet.

This guide is for Windows 10 (version 1809 or newer) and Windows 11.

> **Please read first:** Strongroom is a **pre-release**. It has **not** had an
> independent security audit yet. Keep your old way of storing passwords until
> you have used Strongroom for a while and are happy with it.

---

## 1. Find out which file you need (x64 or ARM64)

There are two versions of the installer. You need the one that matches your
computer.

1. Click **Start**, then **Settings**.
2. Click **System**, then scroll down and click **About**.
3. Look at the line **System type**.

| System type says…                         | Download this file                      |
| ----------------------------------------- | --------------------------------------- |
| "64-bit operating system, x64-based processor" | `Strongroom-Setup-<version>-x64.exe`   |
| "64-bit operating system, ARM-based processor" | `Strongroom-Setup-<version>-arm64.exe` |

Most laptops are **x64**. Laptops with a **Snapdragon** (Qualcomm) chip are
**ARM64**. If your System type says "32-bit", Strongroom cannot run on that
computer.

There is also a file called `SHA256SUMS.txt`. It lets careful users check that
the download was not changed. You can skip it.

---

## 2. The blue "Windows protected your PC" screen

When you open the installer, Windows will probably show a blue box that says
**"Windows protected your PC"**. This is called SmartScreen.

To continue:

1. Click the small link **More info**.
2. Check that the app name is `Strongroom-Setup-…exe`.
3. Click **Run anyway**.

**Why does this happen?** Windows shows this box for programs that are not yet
"signed" with a paid certificate, or that few people have downloaded. This
pre-release of Strongroom is not signed yet. The warning does not mean that a
virus was found. Only click **Run anyway** if you downloaded the file from the
official Strongroom page on GitHub.

Your browser (Edge or Chrome) may also say the file "is not commonly
downloaded". In Edge, click the **…** next to the download, then **Keep**,
then **Show more**, then **Keep anyway**.

---

## 3. Install

1. Double-click the installer file.
2. Pass the SmartScreen box (see step 2 above).
3. Windows may ask how to install: **Install for me only** is the
   recommended choice. It does not need an administrator password.
   (Choose **Install for all users** only if several people share this
   computer and you are an administrator.)
4. Click **Next**. Tick **Create a desktop shortcut** if you want one.
5. Click **Install**, then **Finish**.

Strongroom is now in your **Start** menu.

The program is put in `C:\Users\<your name>\AppData\Local\Programs\Strongroom`.
You do not need to install anything else: everything Strongroom needs is
included.

---

## 4. First start: create your vault

1. Open **Strongroom** from the Start menu.
2. Choose a **master password**. This is the one password you will need to
   remember from now on. Make it long: a few unrelated words is good.
3. Strongroom shows you a **Secret Key**. It is a long code.

### Write down your Secret Key

**Write the Secret Key on paper, and keep the paper somewhere safe at home.**
You can also keep a second copy somewhere else you trust.

You need **both** your master password **and** your Secret Key to open your
vault on a new computer, or to open an exported backup.

> **If you lose your master password or your Secret Key, your passwords are
> gone for ever.** Nobody can get them back for you, not even the people who
> make Strongroom. There is no "forgot password" button. This is on purpose:
> it means nobody else can get in either.

Your vault is saved in this folder:

```
C:\Users\<your name>\AppData\Local\Strongroom
```

### When Strongroom locks itself

Strongroom locks your vault, clears a password you copied and closes the
quick-access window:

- when you lock Windows (**Windows key + L**) or switch to another user;
- before the computer goes to sleep or hibernates;
- when you sign out;
- when you click **Lock** or close Strongroom.

It can also lock after a time without use. In the vault screen, click
**Auto-lock** and choose 5, 15, 30 or 60 minutes. It is **off** at first.
The time counts from your last key press or click in a Strongroom window, or
your last use of the quick-access shortcut.

---

## 5. Windows Hello (fingerprint, face or PIN) - optional

After you unlock your vault with your master password, you can turn on
**Windows Hello** (button in the vault screen). Then you can unlock with your
fingerprint, face or PIN instead of typing the master password every time.
You still need the master password after the computer restarts, every 7 days,
and after 5 wrong tries.

Windows Hello unlock needs a security chip called a **TPM**. Most computers
from 2016 or newer have one. To check:

- Click **Start**, then **Settings**, then **Privacy & security**, then
  **Windows Security**, then **Device security**. If you see
  **Security processor**, your computer has a TPM.
- Or: press **Windows key + R**, type `tpm.msc`, press **Enter**. If it says
  "The TPM is ready for use", you have one. If it says "Compatible TPM cannot
  be found", you do not.

If your computer has no TPM, Strongroom tells you that Windows Hello unlock is
not available. Everything else works normally with your master password.

---

## 6. Bring in your passwords from Edge or Chrome

### Step 1: Save your passwords from the browser to a file

**Microsoft Edge:**

1. Open Edge. Click **…** (top right), then **Settings**.
2. Click **Passwords**.
3. Click the **…** (More actions) next to the list of saved passwords, then
   **Export passwords**.
4. Windows asks for your PIN or Windows password. Enter it.
5. Save the file (it is called something like `Microsoft Edge Passwords.csv`)
   in your **Downloads** folder.

**Google Chrome:**

1. Open Chrome. Click **⋮** (top right), then **Passwords and autofill**, then
   **Google Password Manager**.
2. Click **Settings**, then **Export passwords**, then **Download file**.
3. Enter your Windows PIN or password if asked, and save the file.

### Step 2: Import the file into Strongroom

1. Open and unlock Strongroom.
2. Click **Import passwords (CSV)**, then **From Chrome or Edge**.
   (Use this option for both Edge and Chrome.)
3. Pick the file you just saved.
4. Strongroom tells you how many passwords it added.

### Step 3: Delete the file - important

The file you exported has **all your passwords in plain text**. Anybody who
finds it can read them.

1. Open your **Downloads** folder and delete the `.csv` file.
2. Right-click the **Recycle Bin** on your desktop and click
   **Empty Recycle Bin**.

You can do the same with files from Bitwarden, 1Password or LastPass: use the
matching option in **Import passwords (CSV)**.

---

## 7. Updating Strongroom

Download the new installer and run it, the same way as the first time. You do
not need to uninstall first. Close Strongroom before you start (the installer
offers to close it for you).

**Updating never deletes your vault.**

---

## 8. Uninstalling Strongroom

1. Click **Start**, then **Settings**, then **Apps**, then **Installed apps**.
2. Find **Strongroom**, click **…**, then **Uninstall**.

**Uninstalling removes the program only. Your vault is kept** in
`C:\Users\<your name>\AppData\Local\Strongroom`. Strongroom shows you this
folder when it has finished. If you install Strongroom again, it finds your
vault again.

If you really want to remove your passwords from this computer too, first
make sure you do not need them any more (or that you have an export and your
Secret Key), then delete that folder yourself.

---

## 9. Without installing (portable zip)

If you cannot run installers, use `Strongroom-<version>-x64-portable.zip` (or
`-arm64-portable.zip`):

1. Right-click the `.zip` file, click **Properties**, tick **Unblock** at the
   bottom, click **OK**. (This stops Windows asking about every file.)
2. Right-click the `.zip` again and choose **Extract All**. Pick a folder such
   as **Documents**.
3. Open the extracted **Strongroom** folder and double-click
   **Strongroom.exe**. You may see the SmartScreen box from step 2.

The portable copy uses the same vault folder as the installed one.

---

## 10. Known limits of this pre-release

- **Pre-release, not audited.** No independent security review has been done
  yet.
- **Not signed.** That is why SmartScreen warns you (step 2).
- **Windows Hello has not been tested on real computers yet**, only on
  test machines without a TPM. If it does not work for you, use your master
  password, and please tell us.
- Tested automatically on Windows 11 / Windows Server 2025 test machines
  (x64 and ARM64). Not yet tested by hand on Windows 10.
- Locking on Windows + L, sleep and user switching has only been tested
  automatically, not yet on a real computer.
- No automatic updates: download new versions yourself.
- No browser extension and no syncing between devices. To move your vault,
  use **Export VTF** and **Import VTF**.

Problems or questions: open an issue at
<https://github.com/myselfRaifMondal/strongroom/issues>. **Never** post your
master password, Secret Key or vault file there.
