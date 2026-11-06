# Accounts and your first device

## Accounts

The guided install creates the accounts you listed in your profile (`[household] accounts`); the first is the
first admin. Admin is a role of an account, not of a device.

Day to day, administer from the client's **Admin** section: users, invitations, devices, settings, health and
activity. When no client can open Admin (for example the last admin's devices are gone), use the console in the VM:

```bash
anj-cloud-admin users                     # list accounts
anj-cloud-admin admins
anj-cloud-admin user-add alex --name Alex
anj-cloud-admin admin-grant alex
anj-cloud-admin devices
anj-cloud-admin invite --user sam         # prints a one-time code
anj-cloud-admin revoke <device-id>
anj-cloud-admin health
```

Every action goes through the gateway, so the last-admin rule applies; the audit log records the console as actor.

## Pair the first device

1. In the VM: `sudo anj-cloud-setup pair`. It prints a one-time code (valid ten minutes), waits for the device
   and approves it.
2. Install a client on your device ([clients](../clients.md)), open it, choose **Pair device**, check that the
   server is `https://gateway.example.com`, type the code, and follow [pairing](../pairing.md).

Once the first admin's device is paired, create invitations for the other people and devices from the Admin
section instead.

## Lost last admin

```bash
anj-cloud-admin invite --user sam         # in the VM; type the code on a new device
```

`deploy/README.md` ("Recovery CLI") covers the rest.

Next: [backups and restore](backups.md).
