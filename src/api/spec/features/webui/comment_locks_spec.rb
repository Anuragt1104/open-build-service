require 'browser_helper'

RSpec.describe 'CommentLocks' do
  let!(:moderator_user) { create(:moderator) }

  before do
    Flipper.enable(:content_moderation)
  end

  context 'on a request' do
    let(:submitter) { create(:confirmed_user, :with_home, login: 'kugelblitz') }
    let(:receiver) { create(:confirmed_user, :with_home, login: 'titan') }
    let(:target_project) { receiver.home_project }
    let(:target_package) { create(:package, name: 'goal', project_id: target_project.id) }
    let(:source_project) { submitter.home_project }
    let(:source_package) { create(:package, name: 'ball', project_id: source_project.id) }
    let(:bs_request) { create(:delete_bs_request, target_project: target_project, description: 'a long text - ' * 200, creator: submitter) }
    let(:user) { create(:confirmed_user, :with_home, login: 'burdenski') }

    describe 'with comments unlocked' do
      context 'a moderator user' do
        before do
          login moderator_user
          visit request_show_path(bs_request)
        end

        it 'checks comments are unlocked' do
          find_button('Lock comments')
          expect(page).not_to have_text('Commenting on this is locked. You can remove the lock by clicking on the button below.')
        end

        it 'locks comments' do
          find_button('Lock comments').click
          find_button('Lock').click
          expect(page).to have_text('Commenting on this is locked. You can remove the lock by clicking on the button below.')
        end
      end

      context 'a non-moderator user' do
        before do
          login user
          visit request_show_path(bs_request)
        end

        it 'cannot lock comments' do
          expect(page).not_to have_button('Lock comments')
        end

        it 'can comment' do
          expect(page).not_to have_text('Commenting on this is locked')
          fill_in 'new_comment_body', with: 'Comment Body'
          find_button('Add comment')
        end
      end
    end

    describe 'with comments locked' do
      let!(:comment_lock) { create(:comment_lock, commentable: bs_request, moderator: moderator_user) }

      context 'a moderator user' do
        before do
          login moderator_user
          visit request_show_path(bs_request)
        end

        it 'checks comments are locked' do
          expect(bs_request.comment_lock).not_to be_nil
          find_button('Unlock comments')
          expect(page).to have_text('Commenting on this is locked. You can remove the lock by clicking on the button below.')
        end

        it 'unlocks comments' do
          find_button('Unlock comments').click
          find_button('Unlock').click
          expect(page).not_to have_text('Commenting on this is locked. You can remove the lock by clicking on the button below.')
        end
      end

      context 'a non-moderator user' do
        before do
          login user
          visit request_show_path(bs_request)
        end

        it 'cannot unlock comments' do
          expect(page).not_to have_button('Unlock comments')
          expect(page).not_to have_text('You can remove the lock by clicking on the button below.')
        end

        it 'cannot comment' do
          expect(page).to have_text('Commenting on this is locked')
          expect(page).not_to have_button('Add comment')
        end
      end
    end
  end
end
