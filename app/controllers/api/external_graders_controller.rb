class Api::ExternalGradersController < Api::BaseController
  before_action :auth_by_api_key, only: [:show, :update]
  before_action :auth_by_api_key_and_client_id, only: [:create]

  def show
    participant = Participant.where(api_key: params[:id]).first
    if participant.present?
      message = "Developer API key is valid"
      participant_id = participant.id
      status = :ok
    else
      message = "No participant could be found for this API key"
      participant_id = nil
      status = :not_found
    end
    render json: { message: message, participant_id: participant_id }, status: status
  end


  def create
    message = nil
    status = nil
    submission_id = nil
    submissions_remaining = nil
    reset_dttm = nil
    begin
      participant = Participant.where(api_key: params[:api_key]).first
      raise DeveloperAPIKeyInvalid if participant.nil?
      challenge = Challenge.where(challenge_client_name: params[:challenge_client_name]).first
      challenge_round_id = get_challenge_round_id(challenge)
      raise ChallengeClientNameInvalid if challenge.nil?
      raise ChallengeRoundNotOpen unless challenge_round_open?(challenge)
      raise ParticipantNotQualified unless participant_qualified?(challenge,participant)
      submissions_remaining, reset_dttm = challenge.submissions_remaining(participant.id)
      raise NoSubmissionSlotsRemaining if submissions_remaining < 1
      submission = Submission.create!(participant_id: participant.id,
                                      challenge_id: challenge.id,
                                      challenge_round_id: challenge_round_id,
                                      description_markdown: params[:comment],
                                      post_challenge: post_challenge(challenge),
                                      meta: params[:meta])
      if media_fields_present?
        submission.update({media_large: params[:media_large],
                           media_thumbnail: params[:media_thumbnail],
                           media_content_type: params[:media_content_type]})
      end
      submission.submission_grades.create!(grading_params)
      submission_id = submission.id
      notify_admins(submission)
      message = "Participant #{participant.name} scored"
      status = :accepted
    rescue => e
      status = :bad_request
      message = e
    ensure
      render json: { message: message,
                     submission_id: submission_id,
                     submissions_remaining: submissions_remaining,
                     reset_dttm: reset_dttm }, status: status
    end
  end

  def update
    message = nil
    status = nil
    submission_id = params[:id]
    submissions_remaining = nil
    reset_date = nil
    begin
      submission = Submission.find(submission_id)
      raise SubmissionIdInvalid if submission.blank?
      post_challenge = submission.post_challenge  # preserve post_challenge status
      challenge = submission.challenge
      submissions_remaining, reset_date = challenge.submissions_remaining(submission.participant_id)
      if media_fields_present?
        submission.update({media_large: params[:media_large],
                           media_thumbnail: params[:media_thumbnail],
                           media_content_type: params[:media_content_type]})
        unless Rails.env.test?
          S3Service.new(params[:media_large]).make_public_read
          S3Service.new(params[:media_thumbnail]).make_public_read
        end
      end
      if params[:meta].present?
        submission.update({meta: params[:meta]})
      end
      if params[:grading_status].present?
        submission.submission_grades.create!(grading_params)
      end
      submission.post_challenge = post_challenge
      submission.save
      message = "Submission #{submission.id} updated"
      status = :accepted
    rescue => e
      status = :bad_request
      message = e
    ensure
      render json: { message: message,
                     submission_id: submission_id,
                     submissions_remaining: submissions_remaining,
                     reset_date: reset_date }, status: status
    end
  end

  def submission_info
    begin
      submission = Submission.find(params[:id])
      raise SubmissionIdInvalid if submission.blank?
      message = 'Submission details found.'
      body = submission.to_json
      status = :ok
    rescue => e
      status = :bad_request
      body = nil
      message = e
    ensure
      render json: { message: message,
                     body: body }, status: status
    end
  end

  def presign
    participant = Participant.where(api_key: params[:id]).first
    if participant.present?
      s3_key = "submissions/#{SecureRandom.uuid}"
      signer = Aws::S3::Presigner.new
      presigned_url = signer.presigned_url(:put_object, bucket: ENV['AWS_S3_SHARED_BUCKET'], key: s3_key)
      message = "Presigned url generated"
      participant_id = participant.id
      status = :ok
    else
      message = "No participant could be found for this API key"
      participant_id = nil
      presigned_url = nil
      status = :not_found
    end
    render json: { message: message, participant_id: participant_id, s3_key: s3_key, presigned_url: presigned_url }, status: status
  end

  def post_challenge(challenge)
    if DateTime.now > challenge.end_dttm
      return true
    else
      return false
    end
  end

  def media_fields_present?
    media_large = params[:media_large]
    media_thumbnail = params[:media_thumbnail]
    media_content_type = params[:media_content_type]
    unless (media_large.present? && media_thumbnail.present? && media_content_type.present?) || (media_large.blank? && media_thumbnail.blank? && media_content_type.blank?)
      raise MediaFieldsIncomplete
    end
    if media_large.present? && media_thumbnail.present? && media_content_type.present?
      return true
    end
    if media_large.blank? && media_thumbnail.blank? && media_content_type.blank?
      return false
    end
  end

  def get_challenge_round_id(challenge)
    round = ChallengeRoundSummary.where(challenge_id: challenge.id, round_status_cd: 'current').first
    #raise ChallengeRoundNotOpen if round.empty?
    if round.present?
      return round.id
    else
      return nil
    end
  end

  def challenge_round_open?(challenge)
    return true
    round = ChallengeRoundSummary
              .where(challenge_id: challenge.id, round_status_cd: 'current')
              .where("current_timestamp between start_dttm and end_dttm")
    return false if round.empty?
  end

  def participant_qualified?(challenge,participant)
    return true
  end

  # TODO this needs a rethink
  def validate_s3_key(s3_key)
    S3Service.new(s3_key,shared_bucket=true).valid_key?
  end

  def notify_admins(submission)
    Admin::SubmissionNotificationJob.perform_later(submission)
  end

  private
  def grading_params
    case params[:grading_status]
    when 'graded'
      { score: params[:score],
        score_secondary: params[:score_secondary],
        grading_status_cd: 'graded',
        grading_message: nil }
    when 'submitted'
      { score: nil,
        score_secondary: nil,
        grading_status_cd: 'submitted',
        grading_message: nil }
    when 'failed'
      raise GradingMessageMissing if params[:grading_message].empty?
      { score: nil,
        score_secondary: nil,
        grading_status_cd: 'failed',
        grading_message: params[:grading_message] }
    else
      raise GradingStatusInvalid
    end
  end

  class DeveloperAPIKeyInvalid < StandardError
    def initialize(msg="The API key did not match any participant record.")
      super
    end
  end

  class ChallengeClientNameInvalid < StandardError
    def initialize(msg="The Challenge Client Name string did not match any challenge.")
      super
    end
  end

  class GradingStatusInvalid < StandardError
    def initialize(msg="Grading status must be one of (graded|failed)")
      super
    end
  end

  class GradingMessageMissing < StandardError
    def initialize(msg="Grading message must be provided if grading = failed")
      super
    end
  end

  class SubmissionIdInvalid < StandardError
    def initialize(msg="Submission ID is invalid.")
      super
    end
  end

  class NoSubmissionSlotsRemaining < StandardError
    def initialize(msg="The participant has no submission slots remaining for today.")
      super
    end
  end

  class MediaFieldsIncomplete < StandardError
    def initialize(msg='Either all or none of media_large, media_thumbnail and media_content_type must be provided.')
      super
    end
  end

  class ChallengeRoundNotOpen < StandardError
    def initialize(msg='The challenge is not open for submissions at this time. Please check the challenge page at www.crowdai.org')
      super
    end
  end

  class ParticipantNotQualified < StandardError
    def initialize(msg='You have not qualified for this round. Please review the challenge rules at www.crowdai.org')
      super
    end
  end


end

# curl -i -g -H "Accept: application/vnd.api+json" -H 'Content-Type:application/vnd.api+json' -X GET "https://crowdai-stg.herokuapp.com/api/external_graders/4f2b61e1aaf03d3283f135febbe225a4" -H 'Authorization: Token token="427e6d98d38bb0613cc0f7a9bed26c0d"'

# curl -i -g -H "Accept: application/vnd.api+json" -H 'Content-Type:application/vnd.api+json' -X POST "https://crowdai-stg.herokuapp.com/api/external_graders/?api_key=4f2b61e1aaf03d3283f135febbe225a4&challenge_id=4&comment=test&grading_status=graded&score=0.99" -H 'Authorization: Token token="427e6d98d38bb0613cc0f7a9bed26c0d"'


# local
#curl -i -g -H "Accept: application/vnd.api+json" -H 'Content-Type:application/vnd.api+json' -X POST "localhost:3000/api/external_graders/?api_key=4f2b61e1aaf03d3283f135febbe225a4&challenge_id=4&comment=test&grading_status=graded&score=0.99" -H 'Authorization: Token token="427e6d98d38bb0613cc0f7a9bed26c0d"'

# patch
#curl -i -g -H "Accept: application/vnd.api+json" -H 'Content-Type:application/vnd.api+json' -X PATCH "localhost:3000/api/external_graders/385?media_large=testlarge&media_thumb=test2&media_content_type=videomp4&challenge_id=4&comment=test&grading_status=graded&score=0.99" -H 'Authorization: Token token="427e6d98d38bb0613cc0f7a9bed26c0d"'
#curl -i -g -H "Accept: application/vnd.api+json" -H 'Content-Type:application/vnd.api+json' -X PATCH "localhost:3000/api/external_graders/385?media_content_type=video/mp4&media_large=challenge_8/4f2b61e1aaf03d3283f135febbe225a4___26a21687bc.mp4&media_thumbnail=challenge_8/4f2b61e1aaf03d3283f135febbe225a4___26a21687bc_134x100.mp4"
