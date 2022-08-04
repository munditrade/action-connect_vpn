# Connect to Pritunl VPN
This Github action performs a VPN connection, just provide the following parameters to do the magic


## Parameters

| Name       | Description                | Required |
|------------|----------------------------|----------|
| vpn_config | VPN Config Base64 encoded* |   True   |
|  vpn_pass  | VPN Password or PIN        |   True   |

*vpn_config can be generated with this oneliner and saved as a GitHub secret

```bash
cat config.ovpn | base64 -
```

## Usage

- Usage in your workflow is like following example:

```yaml
name: MyWorkflow

on:
  push:

jobs:
  myexamplejob:
    runs-on: ubuntu-latest
    name: dosomething
    steps:
      - name: Step Connect to VPN
        uses: munditrade/action-connect_vpn@v1
        id: vpn
        with:
          vpn_config: ${{ secrets.VPN_CONFIG }}
          vpn_pass: ${{ secrets.VPN_PASS }}
          
      - name: Step Use Your Internal resources
        run: |
          curl --header "Authorization: bearer xxx" --request GET https://internalresource.example.com/endpoint | jq
```
