import { Controller } from "@hotwired/stimulus"
import { BrowserProvider, getAddress } from "ethers"

export default class extends Controller {
  static targets = ["address", "message", "signature"]

  async connectAndSign() {
    try {
      if (!window.ethereum) {
        alert("No Ethereum provider found. Please install MetaMask.")
        return
      }

      const provider = new BrowserProvider(window.ethereum)
      const accounts = await provider.send("eth_requestAccounts", [])
      const rawAccount = accounts?.[0]

      if (!rawAccount) {
        return // User cancelled wallet selection
      }

      // Normalize to EIP-55 checksummed format
      const account = getAddress(rawAccount)

      // 1) Get nonce from API
      const resp = await fetch(`/api/v1/users/${account.toLowerCase()}`)
      const data = await resp.json().catch(() => null)

      if (!data?.eth_nonce) {
        alert("Failed to get nonce. Please try again.")
        return
      }

      // 2) Get Chain ID from wallet
      const network = await provider.getNetwork()
      const chainId = network.chainId

      // 3) Prepare message with full EIP-4361 compliance: "domain,uri,chainId,AppName,timestamp,nonce"
      const domain = window.location.host
      const uri = window.location.origin
      const timestamp = Math.floor(Date.now() / 1000)
      const message = `${domain},${uri},${chainId},Blockchain Auth,${timestamp},${data.eth_nonce}`

      // 4) Sign message
      const signer = await provider.getSigner()
      const signature = await signer.signMessage(message)

      // 5) Submit form
      this.addressTarget.value = account
      this.messageTarget.value = message
      this.signatureTarget.value = signature

      document.getElementById("wallet-login-form").requestSubmit()
    } catch (error) {
      // Handle user rejection or other errors
      if (error.code === 'ACTION_REJECTED' || error.code === 4001) {
        // User rejected - do nothing (they know what they did)
        console.log('User rejected signature request')
      } else {
        // Other errors - show alert
        console.error('Authentication error:', error)
        alert('Authentication failed. Please try again.')
      }
    }
  }
}