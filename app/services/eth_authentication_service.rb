# frozen_string_literal: true

require "eth"

# Service object for Ethereum signature authentication
# Cache-based implementation - no User creation until successful verification
class EthAuthenticationService
  attr_reader :eth_address, :message, :signature, :request, :errors, :user

  NONCE_TTL = 10.minutes
  MESSAGE_EXPIRATION = 5.minutes # Maximum age of signed message

  # Allowed Chain IDs (EIP-155)
  # 1 = Ethereum Mainnet
  # 5 = Goerli Testnet (deprecated)
  # 11155111 = Sepolia Testnet
  # 137 = Polygon Mainnet
  # 80001 = Polygon Mumbai Testnet
  ALLOWED_CHAIN_IDS = [1, 5, 11155111, 137, 80001].freeze

  def initialize(eth_address:, message:, signature:, request:)
    @eth_address = eth_address.downcase
    @message = message
    @signature = signature
    @request = request
    @errors = []
    @user = nil
  end

  # Perform full authentication flow with security checks
  def authenticate
    return false unless perform_security_checks
    return false unless verify_signature

    # CRITICAL: Create User ONLY after successful verification
    create_or_find_user
    invalidate_nonce
    true
  end

  private

  # Security checks before signature verification
  def perform_security_checks
    # 1. Check if nonce exists in cache
    cached_nonce = Rails.cache.read(nonce_cache_key)
    unless cached_nonce
      @errors << "Nonce not found or expired. Please request a new one."
      return false
    end

    # 2. Check if nonce was already used (one-time use)
    if nonce_already_used?(cached_nonce)
      @errors << "Nonce already used. Please request a new one."
      return false
    end

    # 3. Parse message and verify nonce matches
    unless parse_and_validate_message(cached_nonce)
      return false
    end

    # 4. Mark nonce as used before verification (prevent concurrent attempts)
    mark_nonce_as_used(@cached_nonce)

    true
  end

  # Parse message format: "domain,uri,chainId,AppName,{timestamp},{nonce}"
  # Full EIP-4361 compliance
  def parse_and_validate_message(cached_nonce)
    parts = @message.split(",")
    unless parts.length == 6
      @errors << "Invalid message format. Please try again."
      return false
    end

    @message_domain = parts[0]
    @message_uri = parts[1]
    @message_chain_id = parts[2].to_i
    @app_name = parts[3]
    @timestamp = parts[4].to_i
    @message_nonce = parts[5]

    # Verify domain matches (CRITICAL for preventing cross-site replay attacks)
    expected_domain = @request.host_with_port
    unless @message_domain == expected_domain
      @errors << "Domain mismatch. Please refresh and try again."
      Rails.logger.warn("Domain mismatch: expected '#{expected_domain}', got '#{@message_domain}'")
      return false
    end

    # Verify URI matches (EIP-4361 compliance)
    expected_uri = "#{@request.protocol}#{@request.host_with_port}"
    unless @message_uri == expected_uri
      @errors << "URI mismatch. Please refresh and try again."
      Rails.logger.warn("URI mismatch: expected '#{expected_uri}', got '#{@message_uri}'")
      return false
    end

    # Verify Chain ID is allowed (EIP-155 compliance)
    unless ALLOWED_CHAIN_IDS.include?(@message_chain_id)
      @errors << "Unsupported chain. Please switch to a supported network."
      Rails.logger.warn("Unsupported Chain ID: #{@message_chain_id}. Allowed: #{ALLOWED_CHAIN_IDS.join(', ')}")
      return false
    end

    # Verify nonce matches
    unless @message_nonce == cached_nonce
      @errors << "Nonce mismatch. Please try again."
      return false
    end

    @cached_nonce = cached_nonce
    true
  rescue => e
    Rails.logger.error("Message parsing failed: #{e.class}: #{e.message}")
    @errors << "Unable to parse message. Please try again."
    false
  end

  # Verify Ethereum signature using eth gem
  def verify_signature
    # 1. Check timestamp (not older than 5 minutes)
    if Time.current.to_i - @timestamp > MESSAGE_EXPIRATION.to_i
      @errors << "Signature expired. Please sign a new message."
      return false
    end

    # 2. Check timestamp is not in the future
    if @timestamp > Time.current.to_i
      @errors << "Invalid timestamp. Please check your system time."
      return false
    end

    # 3. Validate Ethereum address format
    unless valid_eth_address?(@eth_address)
      @errors << "Invalid Ethereum address format."
      return false
    end

    # 4. Recover address from signature
    recovered_address = recover_address_from_signature
    unless recovered_address
      return false
    end

    # 5. Compare addresses
    unless recovered_address == @eth_address
      @errors << "Invalid signature. Address mismatch."
      return false
    end

    true
  rescue => e
    Rails.logger.error("Signature verification failed: #{e.class}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    @errors << "Authentication failed. Please try again."
    false
  end

  # Validate Ethereum address format
  def valid_eth_address?(address)
    address.match?(/\A0x[a-f0-9]{40}\z/)
  end

  # Recover Ethereum address from signature
  def recover_address_from_signature
    # Recover public key from signature (personal_sign adds "\x19Ethereum Signed Message:\n" prefix)
    signature_pubkey = Eth::Signature.personal_recover(@message, @signature)

    # Convert public key to Ethereum address
    recovered_address = Eth::Util.public_key_to_address(signature_pubkey).to_s.downcase

    recovered_address
  rescue Eth::Signature::SignatureError => e
    Rails.logger.error("Signature recovery error: #{e.message}")
    @errors << "Invalid signature format."
    nil
  rescue => e
    Rails.logger.error("Address recovery error: #{e.class}: #{e.message}")
    @errors << "Failed to verify signature."
    nil
  end

  def create_or_find_user
    @user = User.find_or_create_by!(eth_address: @eth_address)
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error("Failed to create user: #{e.message}")
    @errors << "Failed to create user account."
    false
  end

  def invalidate_nonce
    # Remove nonce from cache after successful authentication
    Rails.cache.delete(nonce_cache_key)
    Rails.cache.delete(nonce_used_cache_key(@cached_nonce))
  end

  def nonce_cache_key
    "eth_nonce:#{@eth_address}"
  end

  def nonce_used_cache_key(nonce)
    "nonce_used:#{@eth_address}:#{nonce}"
  end

  def nonce_already_used?(nonce)
    Rails.cache.read(nonce_used_cache_key(nonce)).present?
  rescue
    false # Graceful degradation if cache unavailable
  end

  def mark_nonce_as_used(nonce)
    Rails.cache.write(nonce_used_cache_key(nonce), true, expires_in: NONCE_TTL)
  rescue => e
    Rails.logger.warn("Cache unavailable for nonce marking: #{e.message}")
  end
end
