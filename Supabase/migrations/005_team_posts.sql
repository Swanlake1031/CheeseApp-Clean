-- ============================================
-- 005_team_posts.sql
-- 组队模块数据库表
-- 
-- 📖 这是什么？
-- 这个文件创建组队相关的数据库表
-- 用于发布和查找团队组建信息
-- 
-- 📝 使用场景：
-- - 找课程 Group Project 队友
-- - 找 Hackathon 比赛队伍
-- - 找创业/项目合伙人
-- - 找学习小组成员
-- - 找运动/游戏队友
-- ============================================


-- ============================================
-- 组队详情表 (team_posts)
-- ============================================

CREATE TABLE team_posts (
  -- 主键，关联到 posts 表
  id UUID PRIMARY KEY REFERENCES posts(id) ON DELETE CASCADE,
  
  -- ============================================
  -- 分类信息
  -- ============================================
  
  -- category 组队类型
  -- course: 课程项目
  -- hackathon: 黑客松/编程比赛
  -- competition: 其他比赛
  -- startup: 创业项目
  -- study: 学习小组
  -- sports: 运动队伍
  -- gaming: 游戏开黑
  -- other: 其他
  category TEXT NOT NULL CHECK (category IN (
    'course', 'hackathon', 'competition', 'startup',
    'study', 'sports', 'gaming', 'other'
  )),
  
  -- ============================================
  -- 课程相关（如果是 course 类型）
  -- ============================================
  
  -- course_name 课程名称
  -- 例如：CS 101, ECON 201
  course_name TEXT,
  
  -- professor 教授名字
  professor TEXT,
  
  -- ============================================
  -- 团队规模
  -- ============================================
  
  -- team_size 期望的团队总人数
  team_size INTEGER CHECK (team_size >= 1),
  
  -- current_members 当前人数
  current_members INTEGER DEFAULT 1 CHECK (current_members >= 1),
  
  -- spots_available 剩余名额
  -- 这是计算字段，等于 team_size - current_members
  -- 但存储起来方便查询
  spots_available INTEGER CHECK (spots_available >= 0),
  
  -- ============================================
  -- 技能要求
  -- ============================================
  
  -- skills_needed 需要的技能
  -- 存储为 JSONB 数组，例如：["Python", "机器学习", "数据分析"]
  skills_needed JSONB DEFAULT '[]'::JSONB,
  
  -- skills_offered 团队已有的技能
  skills_offered JSONB DEFAULT '[]'::JSONB,
  
  -- ============================================
  -- 时间信息
  -- ============================================
  
  -- deadline 截止日期
  -- 什么时候需要组队完成
  deadline DATE,
  
  -- commitment_hours 每周投入时间
  -- 例如：5 表示每周约 5 小时
  commitment_hours INTEGER CHECK (commitment_hours >= 0),
  
  -- ============================================
  -- 其他信息
  -- ============================================
  
  -- is_remote 是否可以远程协作
  is_remote BOOLEAN DEFAULT TRUE,
  
  -- meeting_location 线下见面地点
  meeting_location TEXT,
  
  -- compensation 是否有报酬/奖金
  -- 对于创业项目或有奖比赛可能有用
  has_compensation BOOLEAN DEFAULT FALSE,
  
  -- compensation_details 报酬详情
  compensation_details TEXT
);


-- ============================================
-- 创建索引
-- ============================================

-- 类别索引
CREATE INDEX team_posts_category_idx ON team_posts (category);

-- 课程名索引（用于搜索）
CREATE INDEX team_posts_course_idx ON team_posts (course_name) WHERE course_name IS NOT NULL;

-- 截止日期索引
CREATE INDEX team_posts_deadline_idx ON team_posts (deadline);

-- 有空位的团队索引
CREATE INDEX team_posts_available_idx ON team_posts (spots_available) WHERE spots_available > 0;

-- 技能搜索索引（使用 GIN 索引加速 JSONB 查询）
CREATE INDEX team_posts_skills_needed_idx ON team_posts USING GIN (skills_needed);


-- ============================================
-- 创建组队帖子的便捷函数
-- ============================================

CREATE OR REPLACE FUNCTION create_team_post(
  p_user_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_category TEXT,
  p_team_size INTEGER DEFAULT NULL,
  p_skills_needed TEXT[] DEFAULT ARRAY[]::TEXT[],
  p_course_name TEXT DEFAULT NULL,
  p_professor TEXT DEFAULT NULL,
  p_deadline DATE DEFAULT NULL,
  p_is_remote BOOLEAN DEFAULT TRUE,
  p_is_anonymous BOOLEAN DEFAULT FALSE
)
RETURNS UUID AS $$
DECLARE
  v_post_id UUID;
BEGIN
  -- 创建基础帖子
  INSERT INTO posts (user_id, type, title, description, is_anonymous)
  VALUES (p_user_id, 'team', p_title, p_description, p_is_anonymous)
  RETURNING id INTO v_post_id;
  
  -- 创建组队详情
  -- current_members 默认为 1（发起者自己）
  -- spots_available = team_size - 1
  INSERT INTO team_posts (
    id, category, team_size, current_members, spots_available,
    skills_needed, course_name, professor, deadline, is_remote
  )
  VALUES (
    v_post_id, p_category, p_team_size, 1,
    CASE WHEN p_team_size IS NOT NULL THEN p_team_size - 1 ELSE NULL END,
    to_jsonb(p_skills_needed), p_course_name, p_professor, p_deadline, p_is_remote
  );
  
  RETURN v_post_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 创建组队帖子视图
-- ============================================

CREATE OR REPLACE VIEW team_posts_view AS
SELECT 
  t.*,
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.view_count,
  p.created_at,
  p.updated_at,
  pr.full_name AS user_name,
  pr.avatar_url AS user_avatar,
  pr.university AS user_university,
  pr.verified AS user_verified,
  -- 计算是否已满员
  CASE 
    WHEN t.spots_available <= 0 THEN TRUE
    ELSE FALSE
  END AS is_full,
  -- 计算是否已截止
  CASE 
    WHEN t.deadline IS NOT NULL AND t.deadline < CURRENT_DATE THEN TRUE
    ELSE FALSE
  END AS is_expired
FROM team_posts t
JOIN posts p ON t.id = p.id
JOIN profiles pr ON p.user_id = pr.id
WHERE p.status = 'active';


-- ============================================
-- 团队成员表
-- ============================================
-- 
-- 🎯 这个表的作用：
-- 记录团队的成员信息
-- 当有人申请加入并被接受后，添加到这个表

CREATE TABLE team_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- 团队帖子
  team_id UUID REFERENCES team_posts(id) ON DELETE CASCADE NOT NULL,
  
  -- 成员
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  
  -- 角色
  -- owner: 发起者/负责人
  -- member: 普通成员
  role TEXT DEFAULT 'member' CHECK (role IN ('owner', 'member')),
  
  -- 状态
  -- pending: 申请中
  -- approved: 已通过
  -- rejected: 已拒绝
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  
  -- 申请留言
  application_message TEXT,
  
  -- 时间
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- 每个用户对每个团队只能有一条记录
  UNIQUE(team_id, user_id)
);


-- ============================================
-- 更新团队人数的触发器
-- ============================================
-- 
-- 🎯 当成员状态变为 approved 时
-- 自动更新 current_members 和 spots_available

CREATE OR REPLACE FUNCTION update_team_members_count()
RETURNS TRIGGER AS $$
BEGIN
  -- 计算已通过的成员数量
  UPDATE team_posts 
  SET 
    current_members = 1 + (
      SELECT COUNT(*) FROM team_members 
      WHERE team_id = NEW.team_id AND status = 'approved'
    ),
    spots_available = CASE 
      WHEN team_size IS NOT NULL 
      THEN team_size - 1 - (
        SELECT COUNT(*) FROM team_members 
        WHERE team_id = NEW.team_id AND status = 'approved'
      )
      ELSE NULL
    END
  WHERE id = NEW.team_id;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER team_members_count_trigger
  AFTER INSERT OR UPDATE ON team_members
  FOR EACH ROW
  EXECUTE FUNCTION update_team_members_count();


-- ============================================
-- 🎉 完成！
-- ============================================
