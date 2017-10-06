## Key Rotation scripts

Not really useable to anyone out of the box, mainly here for my reference

## keyonator.sh
Script used to generate private keys with combined passwords

### Use Case:
Ops team manages encryption service so has access to encrypted data.

No single person should have full access to encrypted data and private key.

One possible solution is to generate private keys with combined passwords


This script will generate private keys with all possible combinations for a given list of team members

```
$ ./keyonator.sh -d /tmp/test -p new -s 4096 -v 365 -t pair

Enter all names separate by space. At least 2 name(s) required
bob john dude emma

Bob
Password:
Confirm:
========

Dude
Password:
Confirm:
========

Emma
Password:
Confirm:
========

John
Password:
Confirm:
========

Master Key
Password:
Confirm:

Generating /tmp/test/master.private.key: OK
Generating public X509 key: OK
Generating /tmp/test/bob-dude.private.key: OK
Generating /tmp/test/bob-emma.private.key: OK
Generating /tmp/test/bob-john.private.key: OK
Generating /tmp/test/dude-emma.private.key: OK
Generating /tmp/test/dude-john.private.key: OK
Generating /tmp/test/emma-john.private.key: OK

Please copy /tmp/test/master.private.key to USB as it will be deleted
Did you do it? (Y|N)  OK

Are you sure? (Y|N)  OK

Last chance!!! (Y|N)  OK

Shredding /tmp/test/master.private.key: OK
```


## encryptonator.sh


Multi-thread script used to decrypt and re-encrypt data on a specific column/table on a mysql database

Use Case:
PCI key rotation of credit card database


