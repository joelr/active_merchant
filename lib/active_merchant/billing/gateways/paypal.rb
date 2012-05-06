require File.dirname(__FILE__) + '/paypal/paypal_common_api'
#require File.dirname(__FILE__) + '/paypal/paypal_recurring_api'
require File.dirname(__FILE__) + '/paypal_express'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class PaypalGateway < Gateway
      include PaypalCommonAPI
      #include PaypalRecurringApi
      
      self.supported_cardtypes = [:visa, :master, :american_express, :discover]
      self.supported_countries = ['US']
      self.homepage_url = 'https://www.paypal.com/cgi-bin/webscr?cmd=_wp-pro-overview-outside'
      self.display_name = 'PayPal Website Payments Pro (US)'
      
      def authorize(money, credit_card_or_referenced_id, options = {})
        requires!(options, :ip)
        commit define_transaction_type(credit_card_or_referenced_id), build_sale_or_authorization_request('Authorization', money, credit_card_or_referenced_id, options)
      end

      def purchase(money, credit_card_or_referenced_id, options = {})
        requires!(options, :ip)
        commit define_transaction_type(credit_card_or_referenced_id), build_sale_or_authorization_request('Sale', money, credit_card_or_referenced_id, options)
      end
      
      def express
        @express ||= PaypalExpressGateway.new(@options)
      end
      
      
      
      def define_transaction_type(transaction_arg)
        if transaction_arg.is_a?(String)
          return 'DoReferenceTransaction'
        else
          return 'DoDirectPayment'
        end
      end
      
      def build_sale_or_authorization_request(action, money, credit_card_or_referenced_id, options)
        transaction_type = define_transaction_type(credit_card_or_referenced_id)
        reference_id = credit_card_or_referenced_id if transaction_type == "DoReferenceTransaction"
        
        billing_address = options[:billing_address] || options[:address]
        currency_code = options[:currency] || currency(money)
       
        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! transaction_type + 'Req', 'xmlns' => PAYPAL_NAMESPACE do
          xml.tag! transaction_type + 'Request', 'xmlns:n2' => EBAY_NAMESPACE do
            xml.tag! 'n2:Version', API_VERSION
            xml.tag! 'n2:' + transaction_type + 'RequestDetails' do
              xml.tag! 'n2:ReferenceID', reference_id if transaction_type == 'DoReferenceTransaction'
              xml.tag! 'n2:PaymentAction', action
              add_payment_details(xml, money, currency_code, options)
              add_credit_card(xml, credit_card_or_referenced_id, billing_address, options) unless transaction_type == 'DoReferenceTransaction'
              xml.tag! 'n2:IPAddress', options[:ip]
            end
          end
        end

        xml.target!        
      end
      
      def add_credit_card(xml, credit_card, address, options)
        xml.tag! 'n2:CreditCard' do
          xml.tag! 'n2:CreditCardType', credit_card_type(card_brand(credit_card))
          xml.tag! 'n2:CreditCardNumber', credit_card.number
          xml.tag! 'n2:ExpMonth', format(credit_card.month, :two_digits)
          xml.tag! 'n2:ExpYear', format(credit_card.year, :four_digits)
          xml.tag! 'n2:CVV2', credit_card.verification_value
          
          if [ 'switch', 'solo' ].include?(card_brand(credit_card).to_s)
            xml.tag! 'n2:StartMonth', format(credit_card.start_month, :two_digits) unless credit_card.start_month.blank?
            xml.tag! 'n2:StartYear', format(credit_card.start_year, :four_digits) unless credit_card.start_year.blank?
            xml.tag! 'n2:IssueNumber', format(credit_card.issue_number, :two_digits) unless credit_card.issue_number.blank?
          end
          
          xml.tag! 'n2:CardOwner' do
            xml.tag! 'n2:PayerName' do
              xml.tag! 'n2:FirstName', credit_card.first_name
              xml.tag! 'n2:LastName', credit_card.last_name
            end
            
            xml.tag! 'n2:Payer', options[:email]
            add_address(xml, 'n2:Address', address)
          end
        end
      end

      def credit_card_type(type)
        case type
        when 'visa'             then 'Visa'
        when 'master'           then 'MasterCard'
        when 'discover'         then 'Discover'
        when 'american_express' then 'Amex'
        when 'switch'           then 'Switch'
        when 'solo'             then 'Solo'
        end
      end
      
      def build_response(success, message, response, options = {})
         Response.new(success, message, response, options)
      end
      
      
      
      
      
      
      
        PAYPAL_NAMESPACE = ActiveMerchant::Billing::PaypalCommonAPI::PAYPAL_NAMESPACE
        API_VERSION = ActiveMerchant::Billing::PaypalCommonAPI::API_VERSION
        EBAY_NAMESPACE = ActiveMerchant::Billing::PaypalCommonAPI::EBAY_NAMESPACE
        # Create a recurring payment.
        #
        # This transaction creates a recurring payment profile
        # ==== Parameters
        #
        # * <tt>money</tt> -- The amount to be charged to the customer at each interval as an Integer value in cents.
        # * <tt>credit_card</tt> -- The CreditCard details for the transaction.
        # * <tt>options</tt> -- A hash of parameters.
        #
        # ==== Options
        #
        # * <tt>:period</tt> -- [Day, Week, SemiMonth, Month, Year] default: Month
        # * <tt>:frequency</tt> -- a number
        # * <tt>:cycles</tt> -- Limit to certain # of cycles (OPTIONAL)
        # * <tt>:start_date</tt> -- When does the charging starts (REQUIRED)
        # * <tt>:description</tt> -- The description to appear in the profile (REQUIRED)

        def recurring(amount, credit_card, options = {})
          options[:credit_card] = credit_card
          options[:amount] = amount
          requires!(options, :description, :start_date, :period, :frequency, :amount)
          commit 'CreateRecurringPaymentsProfile', build_create_profile_request(options)
        end

        # Update a recurring payment's details.
        #
        # This transaction updates an existing Recurring Billing Profile
        # and the subscription must have already been created previously 
        # by calling +recurring()+. The ability to change certain
        # details about a recurring payment is dependent on transaction history
        # and the type of plan you're subscribed with paypal. Web Payment Pro
        # seems to have the ability to update the most field.
        #
        # ==== Parameters
        #
        # * <tt>options</tt> -- A hash of parameters.
        #
        # ==== Options
        #
        # * <tt>:profile_id</tt> -- A string containing the <tt>:profile_id</tt>
        # of the recurring payment already in place for a given credit card. (REQUIRED)
        def update_recurring(options={})
          requires!(options, :profile_id)
          opts = options.dup
          commit 'UpdateRecurringPaymentsProfile', build_change_profile_request(opts.delete(:profile_id), opts)
        end

        # Cancel a recurring payment.
        #
        # This transaction cancels an existing recurring billing profile. Your account must have recurring billing enabled
        # and the subscription must have already been created previously by calling recurring()
        #
        # ==== Parameters
        #
        # * <tt>profile_id</tt> -- A string containing the +profile_id+ of the
        # recurring payment already in place for a given credit card. (REQUIRED)
        # * <tt>options</tt> -- A hash with extra info ('note' for ex.)
        def cancel_recurring(profile_id, options = {})
          raise_error_if_blank('profile_id', profile_id)
          commit 'ManageRecurringPaymentsProfileStatus', build_manage_profile_request(profile_id, 'Cancel', options)
        end

        # Get Subscription Status of a recurring payment profile.
        #
        # ==== Parameters
        #
        # * <tt>profile_id</tt> -- A string containing the +profile_id+ of the
        # recurring payment already in place for a given credit card. (REQUIRED)
        def status_recurring(profile_id)
          raise_error_if_blank('profile_id', profile_id)
          commit 'GetRecurringPaymentsProfileDetails', build_get_profile_details_request(profile_id)
        end

        # Suspends a recurring payment profile.
        #
        # ==== Parameters
        #
        # * <tt>profile_id</tt> -- A string containing the +profile_id+ of the
        # recurring payment already in place for a given credit card. (REQUIRED)
        def suspend_recurring(profile_id, options = {})
          raise_error_if_blank('profile_id', profile_id)
          commit 'ManageRecurringPaymentsProfileStatus', build_manage_profile_request(profile_id, 'Suspend', options)
        end

        # Reactivates a suspended recurring payment profile.
        #
        # ==== Parameters
        #
        # * <tt>profile_id</tt> -- A string containing the +profile_id+ of the
        # recurring payment already in place for a given credit card. (REQUIRED)
        def reactivate_recurring(profile_id, options = {})
          raise_error_if_blank('profile_id', profile_id)
  commit 'ManageRecurringPaymentsProfileStatus', build_manage_profile_request(profile_id, 'Reactivate', options)
        end

        # Bills outstanding amount to a recurring payment profile.
        #
        # ==== Parameters
        #
        # * <tt>profile_id</tt> -- A string containing the +profile_id+ of the
        # recurring payment already in place for a given credit card. (REQUIRED)
        def bill_outstanding_amount(profile_id, options = {})
          raise_error_if_blank('profile_id', profile_id)
          commit 'BillOutstandingAmount', build_bill_outstanding_amount(profile_id, options)
        end

        private
        def raise_error_if_blank(field_name, field)
          raise ArgumentError.new("Missing required parameter: #{field_name}") if field.blank?
        end
        def build_create_profile_request(options)
          xml = Builder::XmlMarkup.new :indent => 2
          xml.tag! 'CreateRecurringPaymentsProfileReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'CreateRecurringPaymentsProfileRequest', 'xmlns:n2' => EBAY_NAMESPACE do
              xml.tag! 'n2:Version', API_VERSION
              xml.tag! 'n2:CreateRecurringPaymentsProfileRequestDetails' do
                xml.tag! 'Token', options[:token] unless options[:token].blank?
                if options[:credit_card]
                  add_credit_card(xml, options[:credit_card], (options[:billing_address] || options[:address]), options)
                end
                xml.tag! 'n2:RecurringPaymentsProfileDetails' do
                  xml.tag! 'n2:BillingStartDate', (options[:start_date].is_a?(Date) ? options[:start_date].to_time : options[:start_date]).utc.iso8601
                  xml.tag! 'n2:ProfileReference', options[:profile_reference] unless options[:profile_reference].blank?
                end
                xml.tag! 'n2:ScheduleDetails' do
                  xml.tag! 'n2:Description', options[:description]
                  xml.tag! 'n2:PaymentPeriod' do
                    xml.tag! 'n2:BillingPeriod', options[:period] || 'Month'
                    xml.tag! 'n2:BillingFrequency', options[:frequency]
                    xml.tag! 'n2:TotalBillingCycles', options[:total_billing_cycles] unless options[:total_billing_cycles].blank?
                    xml.tag! 'n2:Amount', amount(options[:amount]), 'currencyID' => options[:currency] || 'USD'
                    xml.tag! 'n2:TaxAmount', amount(options[:tax_amount] || 0), 'currencyID' => options[:currency] || 'USD' unless options[:tax_amount].blank?
                    xml.tag! 'n2:ShippingAmount', amount(options[:shipping_amount] || 0), 'currencyID' => options[:currency] || 'USD' unless options[:shipping_amount].blank?
                  end
                  if !options[:trial_amount].blank?
                    xml.tag! 'n2:TrialPeriod' do
                      xml.tag! 'n2:BillingPeriod', options[:trial_period] || 'Month'
                      xml.tag! 'n2:BillingFrequency', options[:trial_frequency]
                      xml.tag! 'n2:TotalBillingCycles', options[:trial_cycles] || 1
                      xml.tag! 'n2:Amount', amount(options[:trial_amount]), 'currencyID' => options[:currency] || 'USD'
                      xml.tag! 'n2:TaxAmount', amount(options[:trial_tax_amount] || 0), 'currencyID' => options[:currency] || 'USD' unless options[:trial_tax_amount].blank?
                      xml.tag! 'n2:ShippingAmount', amount(options[:trial_shipping_amount] || 0), 'currencyID' => options[:currency] || 'USD' unless options[:trial_shipping_amount].blank?
                    end
                  end
                  if !options[:initial_amount].blank?
                    xml.tag! 'n2:ActivationDetails' do
                      xml.tag! 'n2:InitialAmount', amount(options[:initial_amount]), 'currencyID' => options[:currency] || 'USD'
                      xml.tag! 'n2:FailedInitialAmountAction', options[:continue_on_failure] ? 'ContinueOnFailure' : 'CancelOnFailure'
                    end
                  end
                  xml.tag! 'n2:MaxFailedPayments', options[:max_failed_payments] unless options[:max_failed_payments].blank?
                  xml.tag! 'n2:AutoBillOutstandingAmount', options[:auto_bill_outstanding] ? 'AddToNextBilling' : 'NoAutoBill'
                end
              end
            end
          end
          xml.target!
        end

        def build_get_profile_details_request(profile_id)
          xml = Builder::XmlMarkup.new :indent => 2
          xml.tag! 'GetRecurringPaymentsProfileDetailsReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'GetRecurringPaymentsProfileDetailsRequest', 'xmlns:n2' => EBAY_NAMESPACE do
              xml.tag! 'n2:Version', API_VERSION
              xml.tag! 'ProfileID', profile_id
            end
          end
          xml.target!
        end

        def build_change_profile_request(profile_id, options)
          xml = Builder::XmlMarkup.new :indent => 2
          xml.tag! 'UpdateRecurringPaymentsProfileReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'UpdateRecurringPaymentsProfileRequest', 'xmlns:n2' => EBAY_NAMESPACE do
              xml.tag! 'n2:Version', API_VERSION
              xml.tag! 'n2:UpdateRecurringPaymentsProfileRequestDetails' do
                xml.tag! 'ProfileID', profile_id
                if options[:credit_card]
                  add_credit_card(xml, options[:credit_card], options[:address], options)
                end
                xml.tag! 'n2:Note', options[:note] unless options[:note].blank?
                xml.tag! 'n2:Description', options[:description] unless options[:description].blank?
                xml.tag! 'n2:ProfileReference', options[:reference] unless options[:reference].blank?
                xml.tag! 'n2:AdditionalBillingCycles', options[:additional_billing_cycles] unless options[:additional_billing_cycles].blank?
                xml.tag! 'n2:MaxFailedPayments', options[:max_failed_payments] unless options[:max_failed_payments].blank?
                xml.tag! 'n2:AutoBillOutstandingAmount', options[:auto_bill_outstanding] ? 'AddToNextBilling' : 'NoAutoBill'
                if options.has_key?(:amount)
                  xml.tag! 'n2:Amount', amount(options[:amount]), 'currencyID' => options[:currency] || 'USD'
                end
                if options.has_key?(:tax_amount)
                  xml.tag! 'n2:TaxAmount', amount(options[:tax_amount] || 0), 'currencyID' => options[:currency] || 'USD'
                end
                if options.has_key?(:start_date)
                  xml.tag! 'n2:BillingStartDate', (options[:start_date].is_a?(Date) ? options[:start_date].to_time : options[:start_date]).utc.iso8601
                end
              end
            end
          end
          xml.target!
        end

        def build_manage_profile_request(profile_id, action, options)
          xml = Builder::XmlMarkup.new :indent => 2
          xml.tag! 'ManageRecurringPaymentsProfileStatusReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'ManageRecurringPaymentsProfileStatusRequest', 'xmlns:n2' => EBAY_NAMESPACE do
              xml.tag! 'n2:Version', API_VERSION
              xml.tag! 'n2:ManageRecurringPaymentsProfileStatusRequestDetails' do
                xml.tag! 'ProfileID', profile_id
                xml.tag! 'n2:Action', action
                xml.tag! 'n2:Note', options[:note] unless options[:note].blank?
              end
            end
          end
          xml.target!
        end

        def build_bill_outstanding_amount(profile_id, options)
          xml = Builder::XmlMarkup.new :indent => 2
          xml.tag! 'BillOutstandingAmountReq', 'xmlns' => PAYPAL_NAMESPACE do
            xml.tag! 'BillOutstandingAmountRequest', 'xmlns:n2' => EBAY_NAMESPACE do
              xml.tag! 'n2:Version', API_VERSION
              xml.tag! 'n2:BillOutstandingAmountRequestDetails' do
                xml.tag! 'ProfileID', profile_id
                if options.has_key?(:amount)
                  xml.tag! 'n2:Amount', amount(options[:amount]), 'currencyID' => options[:currency] || 'USD'
                end
                xml.tag! 'n2:Note', options[:note] unless options[:note].blank?
              end
            end
          end
          xml.target!
        end
      
      
      
      
      
      
      
      
      
      
      
      
      
      
      
      
      
      
      
      
    end
  end
end
