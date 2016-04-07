class Participant < ActiveRecord::Base
  before_save { self.email = email.downcase }

  devise :database_authenticatable, :registerable, :confirmable,
         :recoverable, :rememberable, :trackable, :validatable, :lockable

  VALID_EMAIL_REGEX = /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z]+)*\.[a-z]+\z/i
  validates :email,
    presence: true,
    format: { with: VALID_EMAIL_REGEX },
    uniqueness: { case_sensitive: false }


  has_many :participant_challenges
  has_many :challenges, through: :participant_challenges
  has_many :submissions
  has_many :team_participants
  has_many :teams, through: :team_participants
  has_many :posts
  belongs_to :organizer
  has_one :image, as: :imageable, dependent: :destroy
  accepts_nested_attributes_for :image, allow_destroy: true


  def admin?
    admin
  end

  def avatar
    image.try(:image)
  end

  def avatar_medium_url
    if image.present?
      image.image.url(:medium)
    else
      "//#{ENV['HOST']}/assets/PV_avatar_medium.png"
    end
end
end