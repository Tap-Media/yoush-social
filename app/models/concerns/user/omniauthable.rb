# frozen_string_literal: true

module User::Omniauthable
  extend ActiveSupport::Concern

  TEMP_EMAIL_PREFIX = 'change@me'
  TEMP_EMAIL_REGEX  = /\A#{TEMP_EMAIL_PREFIX}/

  included do
    devise :omniauthable

    def omniauth_providers
      Devise.omniauth_configs.keys
    end

    def email_present?
      email && email !~ TEMP_EMAIL_REGEX
    end
  end

  class_methods do
    def find_for_omniauth(auth, signed_in_resource = nil)
      # EOLE-SSO Patch
      auth.uid = (auth.uid[0][:uid] || auth.uid[0][:user]) if auth.uid.is_a? Hashie::Array
      identity = Identity.find_for_omniauth(auth)

      # If a signed_in_resource is provided it always overrides the existing user
      # to prevent the identity being locked with accidentally created accounts.
      # Note that this may leave zombie accounts (with no associated identity) which
      # can be cleaned up at a later date.
      user   = signed_in_resource || identity.user
      user ||= reattach_for_auth(auth)
      user ||= create_for_auth(auth)

      if identity.user.nil?
        remove_stale_provider_identities_for_auth!(identity, user)
        identity.user = user
        identity.save!
      end

      user
    end

    private

    def reattach_for_auth(auth)
      # If allowed, check if a user exists with the provided email address,
      # and return it if they does not have an associated identity with the
      # current authentication provider.

      # This can be used to provide a choice of alternative auth providers
      # or provide smooth gradual transition between multiple auth providers,
      # but this is discouraged because any insecure provider will put *all*
      # local users at risk, regardless of which provider they registered with.

      return unless ENV['ALLOW_UNSAFE_AUTH_PROVIDER_REATTACH'] == 'true'

      email, email_is_verified = email_from_auth(auth)
      return unless email_is_verified

      user = User.find_by(email: email)
      return if user.nil? || Identity.exists?(provider: auth.provider, user_id: user.id, uid: auth.uid)

      user
    end

    def remove_stale_provider_identities_for_auth!(identity, user)
      return if user.nil?

      Identity.where(provider: identity.provider, user_id: user.id)
              .where.not(id: identity.id)
              .where.not(uid: identity.uid)
              .destroy_all
    end

    def create_for_auth(auth)
      # Create a user for the given auth params. If no email was provided,
      # we assign a temporary email and ask the user to verify it on
      # the next step via Auth::SetupController.show

      email, email_is_verified = email_from_auth(auth)

      user = User.new(user_params_from_auth(email, auth))

      begin
        user.account.avatar_remote_url = auth.info.image if /\A#{URI::DEFAULT_PARSER.make_regexp(%w(http https))}\z/.match?(auth.info.image)
      rescue Mastodon::UnexpectedResponseError
        user.account.avatar_remote_url = nil
      end

      user.mark_email_as_confirmed! if email_is_verified
      user.save!
      user
    end

    def email_from_auth(auth)
      raw_info = raw_info_from_auth(auth)

      [
        email_claim_from_auth(auth, raw_info),
        email_verified_from_auth?(auth, raw_info),
      ]
    end

    def raw_info_from_auth(auth)
      auth.extra&.raw_info
    end

    def email_claim_from_auth(auth, raw_info)
      auth.info.verified_email || auth.info.email || raw_info&.verified_email || raw_info&.email
    end

    def email_verified_from_auth?(auth, raw_info)
      verification_claim = auth.info.verified ||
                           auth.info.verified_email ||
                           auth.info.email_verified ||
                           raw_info&.verified ||
                           raw_info&.verified_email ||
                           raw_info&.email_verified ||
                           assume_email_is_verified?(auth)

      ActiveModel::Type::Boolean.new.cast(verification_claim)
    end

    def assume_email_is_verified?(auth)
      Devise.omniauth_configs[auth.provider.to_sym].strategy&.security&.assume_email_is_verified
    end

    def user_params_from_auth(email, auth)
      {
        email: email || "#{TEMP_EMAIL_PREFIX}-#{auth.uid}-#{auth.provider}.com",
        agreement: true,
        external: true,
        account_attributes: {
          username: ensure_unique_username(ensure_valid_username(username_from_auth(auth))),
          display_name: display_name_from_auth(auth),
        },
      }
    end

    def username_from_auth(auth)
      raw_info = raw_info_from_auth(auth)

      raw_info&.preferred_username.presence ||
        auth.info.nickname.presence ||
        auth.info.email.to_s.split('@')[0].presence ||
        auth.uid
    end

    def ensure_unique_username(starting_username)
      username = starting_username
      i        = 0

      while Account.exists?(username: username, domain: nil)
        i       += 1
        username = "#{starting_username}_#{i}"
      end

      username
    end

    def ensure_valid_username(starting_username)
      starting_username = starting_username.split('@')[0]
      temp_username = starting_username.gsub(/[^a-z0-9_]+/i, '')
      temp_username.truncate(30, omission: '')
    end

    def display_name_from_auth(auth)
      display_name = auth.info.full_name || auth.info.name || [auth.info.first_name, auth.info.last_name].join(' ')
      display_name.truncate(Account::DISPLAY_NAME_LENGTH_LIMIT, omission: '')
    end
  end
end
