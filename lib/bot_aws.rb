require 'singleton'
require 'aws-sdk'
require 'bot_config'
require 'liquid'
require 'git'
require 'zip'
require 'fileutils'
require 'json'

class BotAWS
  include Singleton

  def initialize
    aws_access_key_id = BotConfig.instance.aws_access_key_id
    aws_access_secret_key = BotConfig.instance.aws_access_secret_key
    if ( ! aws_access_key_id || ! aws_access_secret_key)
      puts "Amazon access keys missing"
      return
    end

    AWS.config({
      :access_key_id => aws_access_key_id,
      :secret_access_key => aws_access_secret_key
    })
    @s3 = AWS::S3.new
  end

  def upload_build(bot, upload_bucket, branch_name)
    # Get S3 bucket instance and check for its existance
    s3_bucket = @s3.buckets[upload_bucket]
    if ( ! s3_bucket.exists?)
      puts "S3 bucket \"#{upload_bucket}\" does not exist"
      return
    end

    # Build path to .ipa and check for its existance
    ipa_file_name = File.join(
      '/',
      'Library',
      'Server',
      'Xcode',
      'Data',
      'BotRuns',
      "BotRun-#{bot.latestSuccessfulBotRunGUID}.bundle",
      'output',
      "#{bot.long_name}.ipa"
      )
    if ( ! File.exists?(ipa_file_name))
      puts "File not uploaded. \"#{ipa_file_name}\" does not exist"
      return
    end

    # Extract Info.plist from .ipa
    extract_location = File.join('/', 'tmp', 'gitbot', Time.now.to_i.to_s)
    info_plist_location = File.join(extract_location, 'Info.plist')
    Zip::File.open(ipa_file_name) do |zf|
      zf.each do |e|
        # The file we're looking for is in the root of the <AppName>.app folder
        # and is called Info.plist. The directory heiarchy is Payload/<AppName>.app/...
        # So if the last path component is 'Info.plist' and we're less than 4 compenents
        # deep (Payload/<AppName>.app/Info.plist), this is the plist we're looking for!
        # TODO - find a better way to split path components
        path_array = e.name.split('/')
        if (path_array[-1] == 'Info.plist' && path_array.count < 4)
          FileUtils.mkdir_p(extract_location)
          zf.extract(e, info_plist_location)
          break
        end
      end
    end

    # Check if Info.plist was extracted successfully
    if ( ! File.exists?(info_plist_location))
      puts "Could not extract Info.plist from ipa"
      return
    end

    # Info.plist returned above is in binary format - convert it to xml1 using plutil
    plutil_path = File.join('/', 'usr', 'bin', 'plutil')
    error = %x(#{plutil_path} -convert xml1 #{info_plist_location})
    if ($?.to_i > 0)
      puts "Unable to convert Info.plist from binary to xml - #{error}"
      FileUtils.rm_r(extract_location) # Clean up tmp Info.plist
      return
    end

    # Get build info from Info.plist extracted above
    plist_buddy_path = File.join('/', 'usr', 'libexec', 'PlistBuddy')
    bundle_version_string = %x(#{plist_buddy_path} -c "Print CFBundleVersion" #{info_plist_location}).strip
    bundle_version_string_exit = $?.to_i
    bundle_identifier = %x(#{plist_buddy_path} -c "Print CFBundleIdentifier" #{info_plist_location}).strip
    bundle_identifier_exit = $?.to_i
    bundle_display_name = %x(#{plist_buddy_path} -c "Print CFBundleDisplayName" #{info_plist_location}).strip
    bundle_display_name_exit = $?.to_i

    # Clean up tmp Info.plist
    FileUtils.rm_r(extract_location)

    # Check if any of the above shell commands failed
    if (bundle_version_string_exit > 0 || bundle_identifier_exit > 0 || bundle_display_name_exit > 0)
      puts "Unable to parse build info from Info.plist"
      return
    end

    # Get last build's build version from file
    # Version file is json with the <major.minor> as the key
    # This way each app version has independent build numbers
    version_file_path = File.join('/', 'tmp', 'gitbot', '.last-build-version')
    vs_components = bundle_version_string.split('.')
    major_minor = "#{vs_components[0]}.#{vs_components[1]}"

    if (File.exist?(version_file_path))
      build_versions = JSON.parse(IO.read(version_file_path))
    else
      build_versions = {}
    end
    if (build_versions[major_minor])
      build_version = build_versions[major_minor].to_i
      build_version = build_version + 1
    else
      build_version = 0
    end

    bundle_version_string = "#{major_minor}.#{build_version}"

    upload_display_name = BotConfig.instance.aws_upload_display_name(branch_name)
    title = (upload_display_name ? upload_display_name : "#{bundle_display_name}-#{bundle_version_string}")

    file_name = "#{bundle_identifier}-#{bundle_version_string}"

    # Check for existance of .plist so build is only uploaded ince
    if (s3_bucket.objects["#{file_name}.plist"].exists?)
      puts "A build already exists on S3 for #{title}"
      return # Build already uploaded
    end

    puts "Uploading #{title}..."

    # Upload ipa
    s3_bucket.objects["#{file_name}.ipa"].write(:file => ipa_file_name, :acl => :public_read)
    puts "Uploaded ipa for \"#{title}\" on branch \"#{branch_name}\" to bucket #{upload_bucket}"

    # Create and upload plist
    template_path = File.join(File.dirname(__FILE__), '..', 'templates')
    plist_template = IO.read(File.join(template_path, 'plist.template'))
    template = Liquid::Template.parse(plist_template)
    ipa_url = "https://#{upload_bucket}.s3.amazonaws.com/#{file_name}.ipa"
    plist_string = template.render(
      'ipa_url' => ipa_url,
      'bundle_identifier' => bundle_identifier,
      'version_string' => bundle_version_string,
      'title' => title
      )
    s3_bucket.objects["#{file_name}.plist"].write(plist_string, :acl => :public_read)
    puts "Uploaded plist for \"#{title}\" on branch \"#{branch_name}\" to bucket #{upload_bucket}"

    # Create and upload html file
    builds = []
    custom_file_name = BotConfig.instance.aws_upload_html_file_name(branch_name)
    list_versions = BotConfig.instance.aws_upload_list_all_versions(branch_name)

    if (list_versions) # List each plist found in the bucket
      s3_bucket.objects.each do |object|
        if (object.key.end_with?('plist'))
          url = "https://#{upload_bucket}.s3.amazonaws.com/#{object.key}"
          v_number = object.key.split('-')[-1].sub('.plist', '')
          build = {'url' => url, 'title' => "#{bundle_display_name}-#{v_number}"}
          builds << build
        end
      end
    else # Only list the plist that was just uploaded
      build = {'url' => ipa_url, 'title' => title}
      builds << build
    end
    html_template = IO.read(File.join(template_path, 'html.template'))
    template = Liquid::Template.parse(html_template)
    company_name = BotConfig.instance.company_name
    html_string = template.render('company_name' => company_name, 'builds' => builds)
    html_name = BotConfig.instance.aws_upload_html_file_name(branch_name)
    html_file_name = (html_name ? html_name : "index")
    s3_bucket.objects["#{html_file_name}.html"].write(html_string, :acl => :public_read)
    puts "Uploaded #{html_file_name}.html on branch \"#{branch_name}\" to bucket #{upload_bucket}"

    # Clone or open repo so version can be bumped
    git_url = BotConfig.instance.github_url
    git_repo_name = git_url.sub('.git', '').split('/')[-1]
    temp_path = File.join('/', 'tmp', 'gitbot')
    git_local_path = File.join(temp_path, git_repo_name)
    if (File.directory?(git_local_path))
      puts "Opening repo #{git_repo_name}"
      git = Git.open(git_local_path)
    else
      puts "Cloning repo #{git_repo_name}"
      # FileUtils.mkdir_p shouldn't be nessesary as directory is created when
      # extracting Info.plist, but here just in case the path for repos is changed.
      FileUtils.mkdir_p(temp_path)
      git = Git.clone(git_url, git_repo_name, :path => temp_path)
    end

    # Switch to the proper git branch and checkout commit for this build
    git_branch = git.branch(branch_name)
    git.checkout(git_branch)
    git.pull('origin', git_branch)
    last_commit_hash = git.log.first # :first is the *last* (most recent) commit. Wonderful.
    test_commit_hash = bot.commits[git_url]

    if (last_commit_hash.to_s != test_commit_hash.to_s)
      puts "There has been a commit since #{test_commit_hash} - can not bump version in repo"
      puts "Most recent commit: #{last_commit_hash}"
      return
    end

    # Save build version in project
    agvtool_path = File.join('/', 'usr', 'bin', 'agvtool')
    Dir.chdir(git_local_path)
    error = %x(#{agvtool_path} new-version #{build_version})
    if ($?.to_i > 0)
      puts "Error bumping build version - #{error}"
      return
    end
    puts "Changed build version to #{build_version}"

    # Commit project
    # Making a commit when there's nothing to commit causes an exception
    # Not sure how to see if a status has new commits; I'll just call git myself
    #TODO Figure out how to do this using the git library
    status_output = %x(git status)
    status = status_output.split("\n")[-1]
    if (status.to_s.start_with?('nothing to commit'))
      puts "Nothing to commit - it appears build version wasn't bumped"
    else
      git.commit_all("Bumped build version to #{build_version}.")
      puts "Committed #{branch_name} #{bundle_version_string}"
    end
    tag_prefix = BotConfig.instance.git_tag_prefix(branch_name)
    # If no tag prefix is specified in the config file, then no tag is created
    if (tag_prefix)
      tag_string = "#{tag_prefix}#{bundle_version_string}"
      %x(git tag #{tag_string})
      if ($?.to_i == 0)
        puts "Created tag \"#{tag_string}\" for #{branch_name}"
      end
    end
    git.push(remote = 'origin', branch = branch_name, :tags => true)
    # Mark this new commit as 'success' so the bot isn't triggered by this commit
    BotGithub.instance.create_status_success(git.log.first)
    puts "Pushed #{branch_name} to origin"

    # write build versions back to file
    build_versions[major_minor] = build_version
    IO.write(version_file_path, JSON.pretty_generate(build_versions))
  end
end
