# frozen_string_literal: true

# Copyright (c) 2008-2013 Michael Dvorkin and contributors.
#
# Fat Free CRM is freely distributable under the terms of MIT license.
# See MIT-LICENSE file or http://www.opensource.org/licenses/mit-license.php
#------------------------------------------------------------------------------
# == Schema Information
#
# Table name: campaigns
#
#  id                  :integer         not null, primary key
#  user_id             :integer
#  assigned_to         :integer
#  name                :string(64)      default(""), not null
#  access              :string(8)       default("Public")
#  status              :string(64)
#  budget              :decimal(12, 2)
#  target_leads        :integer
#  target_conversion   :float
#  target_revenue      :decimal(12, 2)
#  leads_count         :integer
#  opportunities_count :integer
#  revenue             :decimal(12, 2)
#  starts_on           :date
#  ends_on             :date
#  objectives          :text
#  deleted_at          :datetime
#  created_at          :datetime
#  updated_at          :datetime
#  background_info     :string(255)
#
module FatFreeCrm
class Campaign < ActiveRecord::Base
  belongs_to :user, optional: true # TODO: Is this really optional?
  belongs_to :assignee, class_name: "User", foreign_key: :assigned_to, optional: true # TODO: Is this really optional?
  has_many :tasks, as: :asset, dependent: :destroy # , :order => 'created_at DESC'
  has_many :leads, -> { order "id DESC" }, dependent: :destroy
  has_many :opportunities, -> { order "id DESC" }, dependent: :destroy
  has_many :emails, as: :mediator
  has_many :email_designs
  has_one :promotion, class_name: "Spree::Promotion", foreign_key: 'campaign_id'

  serialize :subscribed_users, Set

  scope :state, lambda { |filters|
    where('status IN (?)' + (filters.delete('other') ? ' OR status IS NULL' : ''), filters)
  }
  scope :created_by,  ->(user) { where(user_id: user.id) }
  scope :assigned_to, ->(user) { where(assigned_to: user.id) }

  scope :text_search, ->(query) { ransack('name_cont' => query).result }

  uses_user_permissions
  acts_as_commentable
  uses_comment_extensions
  acts_as_taggable_on :tags
  has_paper_trail versions: { class_name: 'FatFreeCrm::Version' }, ignore: [:subscribed_users]
  has_fields
  exportable
  sortable by: ["name ASC", "target_leads DESC", "target_revenue DESC", "leads_count DESC", "revenue DESC", "starts_on DESC", "ends_on DESC", "created_at DESC", "updated_at DESC"], default: "created_at DESC"

  has_ransackable_associations %w[leads opportunities tags activities emails comments tasks]
  ransack_can_autocomplete

  validates_presence_of :name, message: :missing_campaign_name
  validates_uniqueness_of :name, scope: %i[user_id deleted_at]
  validate :start_and_end_dates
  validate :users_for_shared_access
  validates :status, inclusion: { in: proc { Setting.unroll(:campaign_status).map { |s| s.last.to_s } } }, allow_blank: true

  # Default values provided through class methods.
  #----------------------------------------------------------------------------
  def self.per_page
    20
  end

  def save_with_promotion(params)
    # Quick sanitization, makes sure Account will not search for blank id.
    params[:promotion].delete(:id) if params[:promotion][:id].blank?
    promotion = Spree::Promotion.create_or_select_for(self, params[:promotion])
    self.promotion = promotion
    self.save
    self
  end

  # Attach given attachment to the campaign if it hasn't been attached already.
  #----------------------------------------------------------------------------
  def attach!(attachment)
    unless send("#{attachment.class.name.downcase.demodulize}_ids").include?(attachment.id)
      if attachment.is_a?(Task)
        send(attachment.class.name.demodulize.tableize) << attachment
      else # Leads, Opportunities
        attachment.update_attribute(:campaign, self)
        attachment.send("increment_#{attachment.class.name.demodulize.tableize}_count")
        [attachment]
      end
    end
  end

  # Discard given attachment from the campaign.
  #----------------------------------------------------------------------------
  def discard!(attachment)
    if attachment.is_a?(Task)
      attachment.update_attribute(:asset, nil)
    else # Leads, Opportunities
      attachment.send("decrement_#{attachment.class.name.demodulize.tableize}_count")
      attachment.update_attribute(:campaign, nil)
    end
  end

  private

  # Make sure end date > start date.
  #----------------------------------------------------------------------------
  def start_and_end_dates
    errors.add(:ends_on, :dates_not_in_sequence) if (starts_on && ends_on) && (starts_on > ends_on)
  end

  # Make sure at least one user has been selected if the campaign is being shared.
  #----------------------------------------------------------------------------
  def users_for_shared_access
    errors.add(:access, :share_campaign) if self[:access] == "Shared" && permissions.none?
  end

  def self.get_email_designs
    sg = SendGrid::API.new(api_key: Rails.application.credentials[:SENDGRID_API_KEY])
    response = sg.client.marketing.singlesends.get()
    response2 = sg.client.marketing.automations.get()
    JSON.parse(response.body)["result"].each { |d|
      email_design = EmailDesign.find_or_initialize_by(source_info_type: "singlesend", source_info_id: d["id"]) do |e|
        e.source_info_type = "singlesend"
        e.source_info_id = d["id"]
      end
      email_design.source_info = d.to_json
      email_design.save!
    }
    JSON.parse(response2.body).each { |d|
      email_design = EmailDesign.find_or_initialize_by(source_info_type: "automation", source_info_id: d["id"]) do |e|
        e.source_info_type = "automation"
        e.source_info_id = d["id"]
      end
      email_design.source_info = d.to_json
      email_design.save!
    }
    EmailDesign.all
  end

  ActiveSupport.run_load_hooks(:fat_free_crm_campaign, self)
end
end
